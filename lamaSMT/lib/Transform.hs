{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}

{-| Feeding LAMA programs to the SMT solver -}

module Transform where

import Development.Placeholders

import Lang.LAMA.Identifier
import Lang.LAMA.Typing.TypedStructure
import Lang.LAMA.Types
import Language.SMTLib2 as SMT
import Language.SMTLib2.Internals (SMTType(..), SMTExpr(Var, Fun))
import Data.Unit
import Data.String (IsString(..))
import Data.Array as Arr

import Data.Natural
import NatInstance ()
import qualified Data.Map as Map
import Data.Map (Map)
import Prelude hiding (mapM)
import Data.Traversable
import Data.Foldable (foldrM)

import Control.Monad.State (StateT(..), MonadState(..), modify, gets)
import Control.Monad.Error (ErrorT(..), MonadError(..))
import Control.Monad.Reader (ReaderT(..), asks)
import Control.Applicative (Applicative(..), (<$>))
import Control.Arrow (second, (&&&))

import SMTEnum
import RewriteAutomaton

zero' :: SMTExpr Natural
zero' = Var "zero" unit

succ' :: SMTExpr Natural -> SMTExpr Natural
succ' e = Fun "succ" (extractAnnotation e) (extractAnnotation e) `app` e

data TypedExpr i
  = BoolExpr { unBool :: SMTExpr Bool }
  | IntExpr { unInt :: SMTExpr Integer }
  | RealExpr { unReal :: SMTExpr Rational }
  | EnumExpr { unEnum :: SMTExpr SMTEnum }
  | ProdExpr { unProd :: Array Int (TypedExpr i) }
  deriving (Eq, Show)

unBool' :: TypedExpr i -> SMTExpr Bool
unBool' (BoolExpr e) = e
unBool' e = error $ "Cannot unBool: " ++ show e

unProd' :: TypedExpr i -> Array Int (TypedExpr i)
unProd' (ProdExpr e) = e
unProd' e = error $ "Cannot unProd: " ++ show e

type StreamPos = SMTExpr Natural
type Stream t = SMTExpr (SMTFun StreamPos t)
data TypedStream i
  = BoolStream (Stream Bool)
  | IntStream (Stream Integer)
  | RealStream (Stream Rational)
  | EnumStream (Stream SMTEnum)
  | ProdStream (Array Int (TypedStream i))
  deriving Show

mkProdStream :: [TypedStream i] -> TypedStream i
mkProdStream = ProdStream . uncurry listArray . ((0,) . pred . length &&& id)

data Definition =
  SingleDef (Stream Bool)
  | ProdDef (Array Int Definition)
  deriving Show

ensureDefinition :: TypedStream i -> Definition
ensureDefinition (BoolStream s) = SingleDef s
ensureDefinition (ProdStream ps) = ProdDef $ fmap ensureDefinition ps
ensureDefinition s = error $ "ensureDefinition: not a boolean stream: " ++ show s

assertDefinition :: (SMTExpr Bool -> SMTExpr Bool) -> StreamPos -> Definition -> SMT ()
assertDefinition f i (SingleDef s) = assert (f $ s `app` i)
assertDefinition f i (ProdDef ps) = mapM_ (assertDefinition f i) $ Arr.elems ps

-- | Defines a stream analogous to defFun.
defStream :: Ident i => Type i -> (StreamPos -> TypedExpr i) -> DeclM i (TypedStream i)
defStream (GroundType BoolT) f = liftSMT . fmap BoolStream $ defFun (unBool' . f)
defStream (GroundType IntT) f = liftSMT . fmap IntStream $ defFun (unInt . f)
defStream (GroundType RealT) f = liftSMT . fmap RealStream $ defFun (unReal . f)
defStream (GroundType _) f = $notImplemented
defStream (EnumType t) f = lookupEnumAnn t >>= \a -> liftSMT . fmap EnumStream $ defFunAnn unit a (unEnum . f)
-- We have to pull the product out of a stream.
-- If we are given a function f : StreamPos -> (Ix -> TE) = TypedExpr as above,
-- we would like to have as result something like:
-- g : Ix -> (StreamPos -> TE)
-- g(i)(t) = defStream(λt'.f(t')(i))(t)
-- Here i is the index into the product and t,t' are time variables.
defStream (ProdType ts) f =
  do let u = length ts - 1
     x <- mapM (\(ty, i) -> defStream ty ((! i) . unProd' . f)) $ zip ts [0..u]
     return . ProdStream $ listArray (0,u) x

appStream :: TypedStream i -> StreamPos -> TypedExpr i
appStream (BoolStream s) n = BoolExpr $ s `app` n
appStream (IntStream s) n = IntExpr $ s `app` n
appStream (RealStream s) n = RealExpr $ s `app` n
appStream (EnumStream s) n = EnumExpr $ s `app` n
appStream (ProdStream s) n = ProdExpr $ fmap (`appStream` n) s

liftAssert :: TypedExpr i -> SMT ()
liftAssert (BoolExpr e) = assert e
liftAssert (ProdExpr es) = mapM_ liftAssert $ Arr.elems es
liftAssert e = error $ "liftAssert: cannot assert non-boolean expression: " ++ show e

liftRel :: (forall a. SMTType a => SMTExpr a -> SMTExpr a -> SMTExpr Bool)
           -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftRel r (BoolExpr e1) (BoolExpr e2) = BoolExpr $ r e1 e2
liftRel r (IntExpr e1) (IntExpr e2) = BoolExpr $ r e1 e2
liftRel r (RealExpr e1) (RealExpr e2) = BoolExpr $ r e1 e2
liftRel r (EnumExpr e1) (EnumExpr e2) = BoolExpr $ r e1 e2
liftRel r (ProdExpr e1) (ProdExpr e2) = ProdExpr $ accum (liftRel r) e1 (Arr.assocs e2)
liftRel _ _ _ = error "liftRel: argument types don't match"

-- | Only for boolean product streams. Ensures that all fields of
-- a product hold simultaniuosly. Useful for elementwise
-- extended relatations.
prodAll :: TypedExpr i -> TypedExpr i
prodAll (BoolExpr e) = BoolExpr e
prodAll (ProdExpr e) = liftBoolL and' $ Arr.elems e
prodAll e = error $ "prodAll: not a product or boolean expr: " ++ show e

liftOrd :: (forall a. (SMTType a, SMTOrd a) => SMTExpr a -> SMTExpr a -> SMTExpr Bool)
           -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftOrd r (IntExpr e1) (IntExpr e2) = BoolExpr $ r e1 e2
liftOrd r (RealExpr e1) (RealExpr e2) = BoolExpr $ r e1 e2
liftOrd _ _ _ = error "liftRel: argument types don't match or are not ordered"


lift1Bool :: (SMTExpr Bool -> SMTExpr Bool) -> TypedExpr i -> TypedExpr i
lift1Bool f (BoolExpr e) = BoolExpr $ f e
lift1Bool _ _ = error "lift1Bool: argument is not boolean"

liftBool2 :: (SMTExpr Bool -> SMTExpr Bool -> SMTExpr Bool)
             -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftBool2 f (BoolExpr e1) (BoolExpr e2) = BoolExpr $ f e1 e2
liftBool2 _ e1 e2 = error $ "liftBool2: arguments are not boolean: " ++ show e1 ++ "; " ++ show e2

liftBoolL :: ([SMTExpr Bool] -> SMTExpr Bool) -> [TypedExpr i] -> TypedExpr i
liftBoolL f es@((BoolExpr _):_) = BoolExpr . f $ map unBool es
liftBoolL _ es = error $ "Cannot lift bool expr for" ++ show es

lift2 :: (forall a. SMTType a => SMTExpr a -> SMTExpr a -> SMTExpr a)
         -> TypedExpr i -> TypedExpr i -> TypedExpr i
lift2 f (BoolExpr e1) (BoolExpr e2) = BoolExpr $ f e1 e2
lift2 f (IntExpr e1) (IntExpr e2) = IntExpr $ f e1 e2
lift2 f (RealExpr e1) (RealExpr e2) = RealExpr $ f e1 e2
lift2 f (EnumExpr e1) (EnumExpr e2) = EnumExpr $ f e1 e2
lift2 f (ProdExpr e1) (ProdExpr e2) = ProdExpr $ accum (lift2 f) e1 (Arr.assocs e2)
lift2 _ _ _ = error "lift2: argument types don't match"

liftIte :: TypedExpr i -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftIte (BoolExpr c) = lift2 (ite c)
liftIte _ = error "liftIte: condition is not boolean"

liftArith :: (forall a. SMTArith a => SMTExpr a -> SMTExpr a -> SMTExpr a)
              -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftArith f (IntExpr e1) (IntExpr e2) = IntExpr $ f e1 e2
liftArith f (RealExpr e1) (RealExpr e2) = RealExpr $ f e1 e2
liftArith _ _ _ = error "liftArith: argument types don't match or are not aritemetic types"

liftArithL :: (forall a. SMTArith a => [SMTExpr a] -> SMTExpr a)
              -> [TypedExpr i] -> TypedExpr i
liftArithL f es@((IntExpr _):_) = IntExpr . f $ map unInt es
liftArithL f es@((RealExpr _):_) = RealExpr . f $ map unReal es
liftArithL _ _ = error "liftArithL: argument types don't match or are not arithmetic types"

liftInt2 :: (SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer)
              -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftInt2 f (IntExpr e1) (IntExpr e2) = IntExpr $ f e1 e2
liftInt2 _ _ _ = error "liftInt2: argument types are not integers"

liftReal2 :: (SMTExpr Rational -> SMTExpr Rational -> SMTExpr Rational)
              -> TypedExpr i -> TypedExpr i -> TypedExpr i
liftReal2 f (RealExpr e1) (RealExpr e2) = RealExpr $ f e1 e2
liftReal2 _ _ _ = error "liftReal2: argument types are not rational"

data NodeEnv i = NodeEnv
                 { nodeEnvIn :: [TypedStream i]
                 , nodeEnvOut :: [TypedStream i]
                 , nodeEnvVars :: VarEnv i
                 }

data VarEnv i = VarEnv
                { nodes :: Map i (NodeEnv i)
                  -- | Maps names of variables to a SMT expression for using that variable
                , vars :: Map i (TypedStream i)
                }

data Env i = Env
           { constants :: Map i (TypedExpr i)
           , enumAnn :: Map i (SMTAnnotation SMTEnum)
           , enumConsAnn :: Map (EnumConstr i) (SMTAnnotation SMTEnum)
           , varEnv :: VarEnv i
           }

emptyVarEnv :: VarEnv i
emptyVarEnv = VarEnv Map.empty Map.empty

emptyEnv :: Env i
emptyEnv = Env Map.empty Map.empty Map.empty emptyVarEnv

type DeclM i = StateT (Env i) (ErrorT String SMT)

putConstants :: Ident i => Map i (Constant i) -> DeclM i ()
putConstants cs =
  let cs' = fmap trConstant cs
  in modify $ \env -> env { constants = cs' }

putEnumAnn :: Ident i => Map i (SMTAnnotation SMTEnum) -> DeclM i ()
putEnumAnn eAnns =
  modify $ \env -> env { enumAnn = (enumAnn env) `Map.union` eAnns }

putEnumConsAnn :: Ident i => Map (EnumConstr i) (SMTAnnotation SMTEnum) -> DeclM i ()
putEnumConsAnn consAnns =
  modify $ \env -> env { enumConsAnn = (enumConsAnn env) `Map.union` consAnns }

modifyVarEnv :: (VarEnv i -> VarEnv i) -> DeclM i ()
modifyVarEnv f = modify $ \env -> env { varEnv = f $ varEnv env }

modifyNodes :: (Map i (NodeEnv i) -> Map i (NodeEnv i)) -> DeclM i ()
modifyNodes f = modifyVarEnv $ (\env -> env { nodes = f $ nodes env })

modifyVars :: (Map i (TypedStream i) -> Map i (TypedStream i)) -> DeclM i ()
modifyVars f = modifyVarEnv $ (\env -> env { vars = f $ vars env })

lookupErr :: (MonadError e m, Ord k) => e -> k -> Map k v -> m v
lookupErr err k m = case Map.lookup k m of
  Nothing -> throwError err
  Just v -> return v

lookupVar :: Ident i => i -> DeclM i (TypedStream i)
lookupVar x = gets (vars . varEnv) >>= lookupErr ("Unknown variable " ++ identPretty x) x

lookupNode :: Ident i => i -> DeclM i (NodeEnv i)
lookupNode n = gets (nodes . varEnv) >>= lookupErr ("Unknown node " ++ identPretty n) n

lookupEnumAnn :: Ident i => i -> DeclM i (SMTAnnotation SMTEnum)
lookupEnumAnn t = gets enumAnn >>= lookupErr ("Unknown enum " ++ identPretty t) t

lookupEnumConsAnn :: Ident i => EnumConstr i -> DeclM i (SMTAnnotation SMTEnum)
lookupEnumConsAnn x = gets enumConsAnn >>= lookupErr ("Unknown enum constructor " ++ identPretty x) x

localVarEnv :: (VarEnv i -> VarEnv i) -> DeclM i a -> DeclM i a
localVarEnv f m =
  do curr <- get
     modifyVarEnv f
     r <- m
     put curr
     return r

data ProgDefs = ProgDefs
                { flowDef :: [Definition]
                , precondition :: Definition
                , invariantDef :: Definition
                }

lamaSMT :: Ident i => Program i -> ErrorT String SMT (ProgDefs, VarEnv i)
lamaSMT = fmap (second varEnv) . flip runStateT emptyEnv . declProgram

declProgram :: Ident i => Program i -> DeclM i ProgDefs
declProgram p =
  do preamble
     putConstants (progConstantDefinitions p)
     declareEnums (progEnumDefinitions p)
     declDefs <- declareDecls (progDecls p)
     flowDefs <- declareFlow (progFlow p)
     assertInits (progInitial p)
     precondDef <- declarePrecond (progAssertion p)
     invarDef <- declareInvariant (progInvariant p)
     return $ ProgDefs (declDefs ++ flowDefs) precondDef invarDef

preamble :: DeclM i ()
preamble =
  liftSMT $
  declareType (undefined :: Natural) unit

declareEnums :: Ident i => Map (TypeAlias i) (EnumDef i) -> DeclM i ()
declareEnums es =
  do anns <- (fmap Map.fromList . mapM declareEnum $ Map.toList es)
     let consAnns =
           foldl
           (\consAnns (x, EnumDef conss) -> insEnumConstrs (anns Map.! x) consAnns conss)
           Map.empty $ Map.toList es
     putEnumAnn anns
     putEnumConsAnn consAnns
  where
    insEnumConstrs ann = foldl (\consAnns cons -> Map.insert cons ann consAnns)

declareEnum :: Ident i => (TypeAlias i, EnumDef i) -> DeclM i (i, SMTAnnotation SMTEnum)
declareEnum (t, EnumDef cs) =
  let t' = fromString $ identString t
      cs' = map (fromString . identString) cs
      ann = (t', cs')
  in liftSMT (declareType (undefined :: SMTEnum) ann) >> return (t, ann)

declareDecls :: Ident i => Declarations i -> DeclM i [Definition]
declareDecls d =
  do r <- mapM (localVarEnv (const emptyVarEnv) . declareNode) $ declsNode d
     let (defs, interface) = splitIfDefs r
     modifyNodes $ Map.union interface
     locs <- declareVars $ declsLocal d
     states <- declareVars $ declsState d
     modifyVars $ Map.union (locs `Map.union` states)
     return defs
  where
    splitIfDefs = mapAccumL (\ds (x, ds') -> (ds' ++ ds, x)) [] 

declareVars :: Ident i => [Variable i] -> DeclM i (Map i (TypedStream i))
declareVars = fmap Map.fromList . declareVarList

declareVarList :: Ident i => [Variable i] -> DeclM i [(i, TypedStream i)]
declareVarList = mapM declareVar

declareVar :: Ident i => Variable i -> DeclM i (i, TypedStream i)
declareVar (Variable x t) = (x,) <$> typedVar t
  where
    typedVar :: Ident i => Type i -> DeclM i (TypedStream i)
    typedVar (GroundType BoolT) = liftSMT $ fmap BoolStream fun
    typedVar (GroundType IntT) = liftSMT $ fmap IntStream fun
    typedVar (GroundType RealT) = liftSMT $ fmap RealStream fun
    typedVar (GroundType _) = $notImplemented
    typedVar (EnumType t) = lookupEnumAnn t >>= liftSMT . fmap EnumStream . funAnnRet
    typedVar (ProdType ts) =
      do vs <- mapM typedVar ts
         return . ProdStream $ listArray (0, (length vs) - 1) vs

declareNode :: Ident i => Node i -> DeclM i (NodeEnv i, [Definition])
declareNode n =
  do inDecls <- declareVarList $ nodeInputs n
     outDecls <- declareVarList $ nodeOutputs n
     let ins = map snd inDecls
     let outs = map snd outDecls
     modifyVars $ Map.union ((Map.fromList inDecls) `Map.union` (Map.fromList outDecls))
     declDefs <- declareDecls $ nodeDecls n
     flowDefs <- declareFlow $ nodeFlow n
     outDefs <- fmap concat . mapM declareInstantDef $ nodeOutputDefs n
     automDefs <- fmap concat . mapM declareAutomaton . Map.toList $ nodeAutomata n
     assertInits $ nodeInitial n
     precondDef <- declarePrecond $ nodeAssertion n
     varDefs <- gets varEnv
     return (NodeEnv ins outs varDefs,
             declDefs ++ flowDefs ++ outDefs ++ automDefs ++ [precondDef])

declareInstantDef :: Ident i => InstantDefinition i -> DeclM i [Definition]
declareInstantDef (InstantExpr x e) = (:[]) <$> (lookupVar x >>= \x' -> declareDef id x' (trExpr e))
declareInstantDef (NodeUsage x n es) =
  do nEnv <- lookupNode n
     let esTr = map trExpr es
     inpDefs <- mapM (uncurry $ declareDef id) $ zip (nodeEnvIn nEnv) esTr
     outpDef <- declareAssign x (nodeEnvOut nEnv)
     return $ inpDefs ++ [outpDef]

declareTransition :: Ident i => StateTransition i -> DeclM i Definition
declareTransition (StateTransition x e) = lookupVar x >>= \x' -> declareDef succ' x' (trExpr e)

declareDef :: Ident i => (StreamPos -> StreamPos) -> TypedStream i -> TransM i (TypedExpr i) -> DeclM i Definition
declareDef f x em =
  do env <- get
     let defType = streamDefType x
     d <- defStream defType $ \t ->
       let e = runTransM em t env
       in liftRel (.==.) (x `appStream` (f t)) e
     return $ ensureDefinition d
  where
    streamDefType (ProdStream ts) = ProdType . fmap streamDefType $ Arr.elems ts
    streamDefType _ = boolT

declareAssign :: Ident i => i -> [TypedStream i] -> DeclM i Definition
declareAssign _ [] = throwError $ "Cannot assign empty stream"
declareAssign x [y] = lookupVar x >>= \x' -> declareDef id x' (doAppStream y)
declareAssign x ys =
  let y = case ys of
        [y'] -> y
        _ -> mkProdStream ys
  in lookupVar x >>= \x' -> declareDef id x' (doAppStream y)

declareFlow :: Ident i => Flow i -> DeclM i [Definition]
declareFlow f =
  do defDefs <- fmap concat . mapM declareInstantDef $ flowDefinitions f
     transitionDefs <- mapM declareTransition $ flowTransitions f
     return $ defDefs ++ transitionDefs

declareAutomaton :: Ident i => (Int, Automaton i) -> DeclM i [Definition]
declareAutomaton (x, a) =
  let n = "Autom" ++ show x -- FIXME: generate better name!
      (e, sVars, f, i) = mkAutomatonEquations n a
  in do declareEnums e
        declDefs <- declareDecls sVars
        flowDefs <- declareFlow f
        assertInits i
        return $ declDefs ++ flowDefs

assertInits :: Ident i => StateInit i -> DeclM i ()
assertInits = mapM_ assertInit . Map.toList

assertInit :: Ident i => (i, ConstExpr i) -> DeclM i ()
assertInit (x, e) =
  do x' <- lookupVar x
     e' <- trConstExpr e
     let def = liftRel (.==.) (x' `appStream` zero') e'
     liftSMT $ liftAssert def

declarePrecond :: Ident i => Expr i -> DeclM i Definition
declarePrecond e =
  do env <- get
     d <- defStream boolT $ \t -> runTransM (trExpr e) t env
     return $ ensureDefinition d

declareInvariant :: Ident i => Expr i -> DeclM i Definition
declareInvariant = declarePrecond

trConstExpr :: Ident i => ConstExpr i -> DeclM i (TypedExpr i)
trConstExpr (untyped -> Const c) = return $ trConstant c
trConstExpr (untyped -> ConstEnum x) = lookupEnumConsAnn x >>= return . trEnumConsAnn x
trConstExpr (untyped -> ConstProd (Prod cs)) =
  ProdExpr . listArray (0, length cs - 1) <$> mapM trConstExpr cs

trConstant :: Ident i => Constant i -> TypedExpr i
trConstant (untyped -> BoolConst c) = BoolExpr $ constant c
trConstant (untyped -> IntConst c) = IntExpr $ constant c
trConstant (untyped -> RealConst c) = RealExpr $ constant c
trConstant (untyped -> SIntConst n c) = $notImplemented
trConstant (untyped -> UIntConst n c) = $notImplemented

type TransM i = ReaderT (StreamPos, Env i) (Either String)

doAppStream :: TypedStream i -> TransM i (TypedExpr i)
doAppStream s = askStreamPos >>= return . appStream s

-- beware: uses error
runTransM :: TransM i a -> StreamPos -> Env i -> a
runTransM m n e = case runReaderT m (n, e) of
  Left err -> error err
  Right r -> r

lookupVar' :: Ident i => i -> TransM i (TypedStream i)
lookupVar' x =
  do vs <- asks $ vars . varEnv . snd
     case Map.lookup x vs of
       Nothing -> throwError $ "Unknown variable " ++ identPretty x
       Just x' -> return x'

lookupEnumConsAnn' :: Ident i => (EnumConstr i) -> TransM i (SMTAnnotation SMTEnum)
lookupEnumConsAnn' t = asks (enumConsAnn . snd) >>= lookupErr ("Unknown enum constructor " ++ identPretty t) t

askStreamPos :: TransM i StreamPos
askStreamPos = asks fst

-- we do no further type checks since this
-- has been done beforehand.
trExpr :: Ident i => Expr i -> TransM i (TypedExpr i)
trExpr expr =
  let t = getType expr
  in case untyped expr of
    AtExpr (AtomConst c) -> return $ trConstant c
    AtExpr (AtomVar x) ->
      do s <- lookupVar' x
         n <- askStreamPos
         return $ s `appStream` n
    AtExpr (AtomEnum x) -> trEnumCons x
    LogNot e -> lift1Bool not' <$> trExpr e
    Expr2 op e1 e2 -> applyOp op <$> trExpr e1 <*> trExpr e2
    Ite c e1 e2 -> liftIte <$> trExpr c <*> trExpr e1 <*> trExpr e2
    ProdCons (Prod es) -> (ProdExpr . listArray (0, (length es) - 1)) <$> mapM trExpr es
    Project x i ->
      do (ProdStream s) <- lookupVar' x
         n <- askStreamPos
         return $ (s ! fromEnum i) `appStream` n
    Match e pats -> trExpr e >>= flip trPattern pats

trPattern :: Ident i => TypedExpr i -> [Pattern i] -> TransM i (TypedExpr i)
trPattern e@(EnumExpr _) = trEnumMatch e
trPattern _ = $notImplemented

trEnumMatch :: Ident i => TypedExpr i -> [Pattern i] -> TransM i (TypedExpr i)
trEnumMatch x pats =
  -- respect order of patterns here by putting the last in the default match
  -- and bulding the expression bottom-up:
  -- (match x {P_1.e_1, ..., P_n.e_n})
  -- ~> (ite P_1 e_1 (ite ... (ite P_n-1 e_n-1 e_n) ...))
  do innermostPat <- fmap snd . trEnumPattern x $ last pats
     foldrM (chainPatterns x) innermostPat (init pats)
  where
    chainPatterns c p ifs = trEnumPattern c p >>= \(cond, e) -> return $ liftIte cond e ifs
    trEnumPattern c (Pattern h e) = (,) <$> trEnumHead c h <*> trExpr e
    trEnumHead c (EnumPattern e) = trEnumCons e >>= \y -> return $ liftRel (.==.) c y
    trEnumHead _ BottomPattern = return . BoolExpr $ constant True

trEnumConsAnn :: Ident i => EnumConstr i -> SMTAnnotation SMTEnum -> TypedExpr i
trEnumConsAnn x = EnumExpr . constantAnn (SMTEnum . fromString $ identString x)

trEnumCons :: Ident i => EnumConstr i -> TransM i (TypedExpr i)
trEnumCons x = lookupEnumConsAnn' x >>= return . trEnumConsAnn x

applyOp :: BinOp -> TypedExpr i -> TypedExpr i -> TypedExpr i
applyOp Or e1 e2 = liftBoolL or' [e1, e2]
applyOp And e1 e2 = liftBoolL and' [e1, e2]
applyOp Xor e1 e2 = liftBool2 xor e1 e2
applyOp Implies e1 e2 = liftBool2 (.=>.) e1 e2
applyOp Equals e1 e2 = prodAll $ liftRel (.==.) e1 e2
applyOp Less e1 e2 = liftOrd (.<.) e1 e2
applyOp LEq e1 e2 = liftOrd (.<=.) e1 e2
applyOp Greater e1 e2 = liftOrd (.>.) e1 e2
applyOp GEq e1 e2 = liftOrd (.>=.) e1 e2
applyOp Plus e1 e2 = liftArithL plus [e1, e2]
applyOp Minus e1 e2 = liftArith minus e1 e2
applyOp Mul e1 e2 = liftArithL mult [e1, e2]
applyOp RealDiv e1 e2 = liftReal2 divide e1 e2
applyOp IntDiv e1 e2 = liftInt2 div' e1 e2
applyOp Mod e1 e2 = liftInt2 mod' e1 e2