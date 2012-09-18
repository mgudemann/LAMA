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
import Language.SMTLib2.Internals (SMTType(..))
import Data.Unit
import Data.String (IsString(..))
import Data.Array as Arr

import Data.Natural
import NatInstance
import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.Map (Map)
import Prelude hiding (mapM)
import Data.Traversable
import Data.Foldable (foldlM, foldrM)
import Data.Monoid

import Control.Monad (liftM)
import Control.Monad.Trans.Class
import Control.Monad.State (StateT(..), MonadState(..), gets)
import Control.Monad.Error (ErrorT(..), MonadError(..))
import Control.Monad.Reader (ReaderT(..), asks)
import Control.Applicative (Applicative(..), (<$>))
import Control.Arrow ((&&&), first, second)

import SMTEnum
import LamaSMTTypes
import Definition
import TransformEnv

-- | Gets an "undefined" value for a given type of stream.
-- The stream itself is not further analysed.
-- FIXME: Make behaviour configurable, i.e. bottom can be some
-- default value or a left open stream
-- (atm it does the former).
getBottom :: TypedStream i -> TypedExpr i
getBottom (BoolStream _) = BoolExpr $ constant False
getBottom (IntStream _) = IntExpr $ constant 0xdeadbeef
getBottom (RealStream _) = RealExpr . constant $ fromInteger 0xdeadbeef
getBottom (EnumStream s) =
  let ann = extractStreamAnn s
  in EnumExpr $ constantAnn (enumBottom ann) ann
getBottom (ProdStream strs) = ProdExpr $ fmap getBottom strs

-- | Transforms a LAMA program into a set of formulas which is
-- directly declared and a set of defining functions. Those functions
-- can be used to define a cycle by giving it the point in time.
-- Additionally gives back an environment which contains all declared
-- variables together with their defining stream. So if the defining
-- function (see above) is called for a cycle the corresponding stream
-- gets a value at that time (after getting the model).
lamaSMT :: Ident i => NatImplementation -> EnumImplementation -> Program i -> ErrorT String SMT (ProgDefs, VarEnv i)
lamaSMT natImpl' enumImpl' =
  fmap (second varEnv)
  . flip runStateT (emptyEnv natImpl' enumImpl')
  . declProgram

-- | Declare the formulas which define a LAMA program.
declProgram :: Ident i => Program i -> DeclM i ProgDefs
declProgram p =
  do preamble
     putConstants (progConstantDefinitions p)
     declareEnums (progEnumDefinitions p)
     (declDefs, _) <- declareDecls Nothing Set.empty (progDecls p)
     flowDefs <- declareFlow Nothing (progFlow p)
     assertInits (progInitial p)
     precondDef <- declarePrecond Nothing (progAssertion p)
     invarDef <- declareInvariant Nothing (progInvariant p)
     return $ ProgDefs (declDefs ++ flowDefs) precondDef invarDef

-- | Declares common types etc.
-- At the moment just Natural is defined.
preamble :: DeclM i ()
preamble =
  gets natImpl >>= liftSMT . declareType (undefined :: Natural)

declareEnums :: Ident i => Map (TypeAlias i) (EnumDef i) -> DeclM i ()
declareEnums es =
  do anns <- (fmap Map.fromList . mapM declareEnum $ Map.toList es)
     let consAnns =
           foldl
           (\consAnns' (x, EnumDef conss) -> insEnumConstrs (anns Map.! x) consAnns' conss)
           Map.empty $ Map.toList es
     putEnumAnn anns
     putEnumConsAnn consAnns
  where
    insEnumConstrs ann = foldl (\consAnns cons -> Map.insert cons ann consAnns)

declareEnum :: Ident i => (TypeAlias i, EnumDef i) -> DeclM i (i, SMTAnnotation SMTEnum)
declareEnum (t, EnumDef cs) =
  let t' = fromString $ identString t
      cs' = map (fromString . identString) cs
  in do ann <- gets enumImpl >>= \impl -> return $ mkSMTEnumAnn impl t' cs'
        liftSMT (declareType (undefined :: SMTEnum) ann) >> return (t, ann)

declareDecls :: Ident i => Maybe (Stream Bool) -> Set i -> Declarations i -> DeclM i ([Definition], Map i (Node i))
declareDecls activeCond excludeNodes d =
  do let (excluded, toDeclare) = Map.partitionWithKey (\n _ -> n `Set.member` excludeNodes) $ declsNode d
     defs <- mapM (uncurry $ declareNode activeCond) $ Map.toList toDeclare
     (inp, constr1) <- declareVars $ declsInput d
     (locs, constr2) <- declareVars $ declsLocal d
     (states, constr3) <- declareVars $ declsState d
     modifyVars $ mappend (inp `mappend` locs `mappend` states)
     return (concat defs ++ constr1 ++ constr2 ++ constr3, excluded)

declareVars :: Ident i => [Variable i] -> DeclM i (Map i (TypedStream i), [Definition])
declareVars = fmap (first Map.fromList) . declareVarList

declareVarList :: Ident i => [Variable i] -> DeclM i ([(i, TypedStream i)], [Definition])
declareVarList = liftM (second concat . unzip) . mapM declareVar

declareVar :: Ident i => Variable i -> DeclM i ((i, TypedStream i), [Definition])
declareVar (Variable x t) =
  do natAnn <- gets natImpl
     first (x,) <$> typedVar natAnn t
  where
    typedVar :: Ident i => SMTAnnotation Natural -> Type i -> DeclM i (TypedStream i, [Definition])
    typedVar ann (GroundType BoolT) = liftSMT $ fmap ((, []) . BoolStream) $ funAnn ann unit
    typedVar ann (GroundType IntT) = liftSMT $ fmap ((, []) . IntStream) $ funAnn ann unit
    typedVar ann (GroundType RealT) = liftSMT $ fmap ((, []) . RealStream) $ funAnn ann unit
    typedVar ann (GroundType _) = $notImplemented
    typedVar ann (EnumType et) = lookupEnumAnn et >>= fmap (first EnumStream) . enumVar ann
    typedVar ann (ProdType ts) =
      do (vs, constraints) <- liftM (second concat . unzip) $ mapM (typedVar ann) ts
         return (ProdStream $ listArray (0, (length vs) - 1) vs, constraints)

enumVar :: MonadSMT m
           => SMTAnnotation Natural -> SMTAnnotation SMTEnum
           -> m (Stream SMTEnum, [Definition])
enumVar argAnn ann@(EnumTypeAnn _ _ _) = liftSMT (funAnn argAnn ann) >>= return . (, [])
enumVar argAnn ann@(EnumBitAnn size _ biggestCons) =
  do v <- liftSMT (funAnn argAnn ann)
     constr <- liftSMT $ defFunAnn argAnn unit $ \t -> bvule ((toBVExpr v) `app` t) (constantAnn biggestCons size)
     return (v, [SingleDef constr])

-- | Declares a node and puts the interface variables into the environment.
-- Here it becomes crucial that a node is used at most once in a program, since
-- otherwise there would rise conflicting definitions for the inputs.
-- 
-- Nodes used inside a location of an automaton get some special handling. First
-- the automata are analysed to find out which nodes are used inside a location
-- (using getNodesInLocations). Then all nodes _except_ those found before are
-- declared. The other nodes are deferred to be declared in the corresponding
-- location (see declareAutomaton and declareLocations).
declareNode :: Ident i => Maybe (Stream Bool) -> i -> Node i -> DeclM i [Definition]
declareNode active nName nDecl =
  do (interface, defs) <- localVarEnv (const emptyVarEnv) $ declareNode' active nDecl
     modifyNodes $ Map.insert nName interface
     return defs
  where
    declareNode' :: Ident i => Maybe (Stream Bool) -> Node i -> DeclM i (NodeEnv i, [Definition])
    declareNode' activeCond n =
      do let automNodes = mconcat . map getNodesInLocations . Map.elems $ nodeAutomata n
         (declDefs, undeclaredNodes) <- declareDecls activeCond automNodes $ nodeDecls n
         (outDecls, constr1) <- declareVarList $ nodeOutputs n
         ins <- mapM (lookupVar . varIdent) . declsInput $ nodeDecls n
         let outs = map snd outDecls
         modifyVars $ Map.union (Map.fromList outDecls)
         flowDefs <- declareFlow activeCond $ nodeFlow n
         automDefs <- fmap concat . mapM (declareAutomaton activeCond undeclaredNodes) . Map.toList $ nodeAutomata n
         assertInits $ nodeInitial n
         precondDef <- declarePrecond activeCond $ nodeAssertion n
         varDefs <- gets varEnv
         return (NodeEnv ins outs varDefs,
                 declDefs ++ constr1 ++ flowDefs ++ automDefs ++ [precondDef])

-- | Extracts all nodes which are used inside some location.
getNodesInLocations :: Ident i => Automaton i -> Set i
getNodesInLocations = mconcat . map getUsedLoc . automLocations
  where
    getUsedLoc :: Ident i => Location i -> Set i
    getUsedLoc (Location _ flow) = mconcat . map getUsed $ flowDefinitions flow
    getUsed (NodeUsage _ n _) = Set.singleton n
    getUsed _ = Set.empty

-- | Creates definitions for instant definitions. In case of a node usage this may
-- produce multiple definitions. If 
declareInstantDef :: Ident i => Maybe (Stream Bool) -> InstantDefinition i -> DeclM i [Definition]
declareInstantDef activeCond inst@(InstantExpr x _) =
  do (res, []) <- trInstant (error "no activation condition") inst
     xStream <- lookupVar x
     def <- declareConditionalAssign activeCond id (const $ getBottom xStream) xStream res
     return [def]
declareInstantDef activeCond inst@(NodeUsage x _ _) =
  do (outp, inpDefs) <- trInstant activeCond inst
     xStream <- lookupVar x
     outpDef <- declareConditionalAssign activeCond id (const $ getBottom xStream) xStream outp
     return $ inpDefs ++ [outpDef]

-- | Translates an instant definition into a function which can be
-- used to further refine this instant (e.g. wrap it into an ite).
-- This may also return definitions of the parameters of a node.
-- The activation condition is only used for the inputs of a node.
trInstant :: Ident i => Maybe (Stream Bool) -> InstantDefinition i ->
             DeclM i (Env i -> StreamPos -> TypedExpr i, [Definition])
trInstant _ (InstantExpr _ e) = return (runTransM $ trExpr e, [])
trInstant inpActive (NodeUsage _ n es) =
  do nEnv <- lookupNode n
     let esTr = map (runTransM . trExpr) es
     inpDefs <- mapM (\(x, e) -> declareConditionalAssign inpActive id (const $ getBottom x) x e)
                $ zip (nodeEnvIn nEnv) esTr
     let y = mkProdStream (nodeEnvOut nEnv)
     return (const $ appStream y, inpDefs)

-- | Creates a declaration for a state transition.
-- If an activation condition c is given, the declaration boils down to
-- x' = (ite c e x) where e is the defining expression. Otherwise it is just
-- x' = e.
declareTransition :: Ident i => Maybe (Stream Bool) -> StateTransition i -> DeclM i Definition
declareTransition activeCond (StateTransition x e) =
  lookupVar x >>= \xStream ->
  gets natImpl >>= \natAnn ->
  declareConditionalAssign activeCond (succ' natAnn) (appStream xStream) xStream (runTransM $ trExpr e)

-- | Creates a declaration for an assignment. Depending on the
-- activation condition the given expression or a default expression
-- is used (generated by genDefault). Additionally the position in the
-- stream of /x/ which will be defined, can be specified by modPos
-- (see declareDef).
declareConditionalAssign :: Ident i => Maybe (Stream Bool) ->
                       (StreamPos -> StreamPos) ->
                       (StreamPos -> TypedExpr i) ->
                       TypedStream i -> (Env i -> StreamPos -> TypedExpr i) -> DeclM i Definition
declareConditionalAssign activeCond modPos defaultStream x ef =
  case activeCond of
    Nothing -> declareDef modPos x ef
    Just c -> declareDef modPos x
              (\env t -> mkConditionalStream t c (ef env) defaultStream)
  where
    -- | Takes a condition and the corresponding branches which may depend
    -- on the current time and builds an expression which takes the corresponding
    -- branch depending on the condition (if c then s_1(n) else s_2(n)).
    mkConditionalStream n c s1 s2 =
      let c' = BoolExpr $ c `app` n
      in liftIte c' (s1 n) (s2 n)

-- | Creates a definition for a given variable. Whereby a function to
-- manipulate the stream position at which it is defined is used (normally
-- id or succ' to define instances or state transitions).
-- The second argument /x/ is the stream to be defined and the last
-- argument (/ef/) is a function that generates the defining expression.
declareDef :: Ident i => (StreamPos -> StreamPos) -> TypedStream i ->
              (Env i -> StreamPos -> TypedExpr i) -> DeclM i Definition
declareDef f x ef =
  do env <- get
     let defType = streamDefType x
     d <- defStream defType $ \t ->
       liftRel (.==.) (x `appStream` (f t)) (ef env t)
     return $ ensureDefinition d
  where
    streamDefType (ProdStream ts) = ProdType . fmap streamDefType $ Arr.elems ts
    streamDefType _ = boolT

declareFlow :: Ident i => Maybe (Stream Bool) -> Flow i -> DeclM i [Definition]
declareFlow activeCond f =
  do defDefs <- fmap concat . mapM (declareInstantDef activeCond) $ flowDefinitions f
     transitionDefs <- mapM (declareTransition activeCond) $ flowTransitions f
     return $ defDefs ++ transitionDefs

-- | Declares an automaton by
-- * defining an enum for the locations
-- * defining two variables which hold the active location (see mkStateVars)
-- * ordering the data flow from the locations by the defined variables (see extractAssigns)
-- * defining formulas for each variables (see declareLocations)
-- * defining the variables for the active location by using the edge conditions (mkTransitionEq)
-- * asserting the initial location
declareAutomaton :: Ident i => Maybe (Stream Bool) -> Map i (Node i) -> (Int, Automaton i) -> DeclM i [Definition]
declareAutomaton activeCond localNodes (_, a) =
  do automIndex <- nextAutomatonIndex
     let automName = "Autom" ++ show automIndex
         enumName = fromString $ automName ++ "States"
         stateT = EnumType enumName
         locNames = Map.fromList . map (id &&& (locationName automName . runLocationId)) $ map getLocId (automLocations a)
         locCons = fmap EnumCons locNames
         enum = EnumDef $ Map.elems locCons
         sName = fromString $ "s" ++ (identString enumName)
         s_1Name = fromString $ "s_1" ++ (identString enumName)
     declareEnums $ Map.singleton enumName enum
     ((s, s_1), constr) <- mkStateVars enumName
     modifyVars (`Map.union` Map.fromList [(sName, EnumStream $ s), (s_1Name, EnumStream $ s_1)])
     locDefs <- (flip runReaderT (locCons, localNodes))
                $ declareLocations activeCond s
                (automDefaults a) (automLocations a)
     edgeDefs <- mkTransitionEq activeCond stateT locCons sName s_1Name $ automEdges a
     assertInit (s_1Name, locConsConstExpr locCons stateT $ automInitial a)
     return $ constr ++ locDefs ++ edgeDefs

  where
    getLocId (Location i _) = i

    -- | Create the name for a location (original name
    -- prefixed by the automaton name).
    locationName :: Ident i => String -> i -> i
    locationName automName sName = fromString $ automName ++ identString sName

    -- | Create the enum constructor for a given location name as constant.
    locConsConstExpr :: Ord i => Map (LocationId i) (EnumConstr i) -> Type i -> LocationId i -> ConstExpr i
    locConsConstExpr locNames t loc = mkTyped (ConstEnum ((Map.!) locNames loc)) t

-- | Generate names of two variable which represent
-- the state of the automaton (s, s_1). Where
-- s represents the current state which is calculated
-- at the beginning of a clock cycle. s_1 saves this
-- state for the next cycle.
mkStateVars :: Ident i => i -> DeclM i ((Stream SMTEnum, Stream SMTEnum), [Definition])
mkStateVars stateEnum =
  do enumAnn <- lookupEnumAnn stateEnum
     natAnn <- gets natImpl
     (s, constr1) <- enumVar natAnn enumAnn
     (s_1, constr2) <- enumVar natAnn enumAnn
     return ((s, s_1), constr1 ++ constr2)

-- | Extracts the the expressions for each variable seperated into
-- local definitons and state transitions.
extractAssigns :: Ord i => [Location i]
                  -> (Map i [(LocationId i, InstantDefinition i)], Map i [(LocationId i, StateTransition i)])
extractAssigns = foldl addLocExprs (Map.empty, Map.empty)
  where
    addLocExprs (defExprs, stateExprs) (Location l flow) =
      (foldl (\defs inst -> putInstant l inst defs) defExprs $ flowDefinitions flow,
       foldl (\transs trans -> putTrans l trans transs) stateExprs $ flowTransitions flow)

    putDef d Nothing = Just $ [d]
    putDef d (Just ds) = Just $ d : ds

    putInstant l inst@(InstantExpr x _) = Map.alter (putDef (l, inst)) x
    putInstant l inst@(NodeUsage x _ _) = Map.alter (putDef (l, inst)) x

    putTrans l trans@(StateTransition x _) = Map.alter (putDef (l, trans)) x

-- | Transports the mapping LocationId -> EnumConstr which was defined
-- beforehand and the undeclared nodes which are used in one of the
-- locations of the automata to be defined.
type AutomTransM i = ReaderT (Map (LocationId i) (EnumConstr i), Map i (Node i)) (DeclM i)

lookupLocName :: Ident i => LocationId i -> AutomTransM i (EnumConstr i)
lookupLocName l = asks fst >>= lookupErr ("Unknown location " ++ identPretty l) l

lookupLocalNode :: Ident i => i -> AutomTransM i (Node i)
lookupLocalNode n = asks snd >>= lookupErr ("Unknow local node " ++ identPretty n) n

-- | Declares the data flow inside the locations of an automaton.
declareLocations :: Ident i => Maybe (Stream Bool) -> Stream SMTEnum ->
                    Map i (Expr i) -> [Location i] -> AutomTransM i [Definition]
declareLocations activeCond s defaultExprs locations =
  let (defs, trans) = extractAssigns locations
      defs' = defs `Map.union` (fmap (const []) defaultExprs) -- add defaults for nowhere defined variables
  in do instDefs <- fmap concat . mapM (declareLocDefs activeCond defaultExprs) $ Map.toList defs'
        transDefs <- mapM (declareLocTransitions activeCond) $ Map.toList trans
        return $ instDefs ++ transDefs
  where
    declareLocDefs :: Ident i => Maybe (Stream Bool) -> Map i (Expr i)
                      -> (i, [(LocationId i, InstantDefinition i)]) -> AutomTransM i [Definition]
    declareLocDefs active defaults (x, locs) =
      do defaultExpr <- getDefault defaults x locs
         (res, inpDefs) <- declareLocDef active s defaultExpr locs
         xStream <- lookupVar x
         def <- lift $ declareConditionalAssign active id (const $ getBottom xStream) xStream res
         return $ inpDefs ++ [def]

    declareLocTransitions :: Ident i => Maybe (Stream Bool)
                       -> (i, [(LocationId i, StateTransition i)]) -> AutomTransM i Definition
    declareLocTransitions active (x, locs) =
      do res <- trLocTransition s locs
         xStream <- lookupVar x
         natAnn <- gets natImpl
         def <- lift $ declareConditionalAssign active (succ' natAnn) (appStream xStream) xStream res
         return def

    getDefault defaults x locs =
      do fullyDefined <- isFullyDefined locs
         if fullyDefined
           then return Nothing
           else fmap Just $ lookupErr (identPretty x ++ " not fully defined") x defaults

    isFullyDefined locDefs =
      do locNames <- asks fst
         return $ (Map.keysSet locNames) == (Set.fromList $ map fst locDefs)

declareLocDef :: Ident i => Maybe (Stream Bool) -> Stream SMTEnum
                 -> Maybe (Expr i)
                 -> [(LocationId i, InstantDefinition i)]
                 -> AutomTransM i (Env i -> StreamPos -> TypedExpr i, [Definition])
declareLocDef activeCond s defaultExpr locs =
  do (innerPat, locs') <- case defaultExpr of
       Nothing -> case locs of (l:ls) -> (, ls) <$> uncurry (trLocInstant activeCond) l
       Just e -> return ((runTransM $ trExpr e, []), locs)
     foldlM (\(f, defs) (l, inst) -> trLocInstant activeCond l inst >>= \(res, defs') ->
              mkLocationMatch s f l res >>=
              return . (, defs ++ defs'))
       innerPat locs'
  where
    trLocInstant :: Ident i => Maybe (Stream Bool)
                    -> LocationId i -> InstantDefinition i
                    -> AutomTransM i (Env i -> StreamPos -> TypedExpr i, [Definition])
    trLocInstant _ _ inst@(InstantExpr _ _) = lift $ trInstant (error "no activation condition required") inst
    trLocInstant active l inst@(NodeUsage _ n _) =
      do (locationActive, activeDef) <- mkLocationActivationCond active s l
         node <- lookupLocalNode n
         nodeDefs <- lift $ declareNode (Just locationActive) n node
         (r, inpDefs) <- lift $ trInstant (Just locationActive) inst
         return (r, [activeDef] ++ nodeDefs ++ inpDefs)

trLocTransition :: Ident i => Stream SMTEnum
                      -> [(LocationId i, StateTransition i)]
                      -> AutomTransM i (Env i -> StreamPos -> TypedExpr i)
trLocTransition s locs =
  let (innerPat, locs') = case locs of (l:ls) -> (trLocTrans $ snd l, ls)
  in foldlM (\f -> uncurry (mkLocationMatch s f) . second trLocTrans) innerPat locs'
  where
    trLocTrans (StateTransition _ e) = runTransM $ trExpr e

mkLocationMatch :: Ident i => Stream SMTEnum
                   -> (Env i -> StreamPos -> TypedExpr i)
                   -> LocationId i -> (Env i -> StreamPos -> TypedExpr i)
                   -> AutomTransM i (Env i -> StreamPos -> TypedExpr i)
mkLocationMatch s f l lExpr =
  do lCons <- lookupLocName l
     lEnum <- lift $ trEnumConsAnn lCons <$> lookupEnumConsAnn lCons
     return
       (\env t -> liftIte
                  (BoolExpr $ (s `app` t) .==. lEnum)
                  (lExpr env t)
                  (f env t))

-- | Creates a variable which is true iff the given activation
-- condition is true and the the given location is active.
mkLocationActivationCond :: Ident i => Maybe (Stream Bool) -> Stream SMTEnum
                            -> LocationId i -> AutomTransM i (Stream Bool, Definition)
mkLocationActivationCond activeCond s l =
  do lCons <- lookupLocName l
     lEnum <- lift $ trEnumConsAnn lCons <$> lookupEnumConsAnn lCons
     natAnn <- gets natImpl
     let cond = \_env t -> BoolExpr $ (s `app` t) .==. lEnum
     activeVar <- liftSMT $ funAnn natAnn unit
     def <- lift $ declareConditionalAssign activeCond id
            (const . BoolExpr $ constant False) (BoolStream activeVar) cond
     return (activeVar, def)

-- | Creates two equations for the edges. The first calculates
-- the next location (s). This is a chain of ite for each state surrounded
-- by a match on the last location (s_1). The definition of s_1 is just
-- the saving of s for the next cycle.
mkTransitionEq :: Ident i => Maybe (Stream Bool) -> Type i -> Map (LocationId i) (EnumConstr i)
                  -> i -> i
                  -> [Edge i] -> DeclM i [Definition]
mkTransitionEq activeCond locationEnumTy locationEnumConstrs s s_1 es =
  -- we reuse the translation machinery by building a match expression and
  -- translating that.
  -- We use foldr to enforce that transition that occur later in the
  -- source get a lower priority.
  do stateDef <- declareInstantDef activeCond
                 . InstantExpr s
                 . mkMatch locationEnumConstrs locationEnumTy s_1 (mkTyped (AtExpr $ AtomVar s_1) locationEnumTy)
                 . Map.toList
                 $ foldr addEdge Map.empty es
     stateTr <- declareTransition activeCond
                $ StateTransition s_1 (mkTyped (AtExpr $ AtomVar s) locationEnumTy)
     return $ stateDef ++ [stateTr]
  where
     addEdge (Edge h t c) m =
       Map.alter
       (extendStateExpr locationEnumTy
        (locConsExpr locationEnumConstrs locationEnumTy h)
        (locConsExpr locationEnumConstrs locationEnumTy t) c)
       h m

     -- | Build up the expression which calculates the next
     -- state for each given state. This is a chain of ite's for
     -- each state.
     extendStateExpr :: Type i -> Expr i -> Expr i -> Expr i -> Maybe (Expr i) -> Maybe (Expr i)
     extendStateExpr sT h t c Nothing = Just $ mkTyped (Ite c t h) sT
     extendStateExpr _ _ t c (Just e) = Just $ preserveType (Ite c t) e

     -- | Build match expression (pattern matches on last state s_1)
     mkMatch :: Ord i => Map (LocationId i) (EnumConstr i) -> Type i -> i -> Expr i -> [(LocationId i, Expr i)] -> Expr i
     mkMatch locCons locationT s_1 defaultExpr locExprs =
       mkTyped (
         Match (mkTyped (AtExpr $ AtomVar s_1) locationT)
         $ (mkPattern locExprs) ++ (mkDefaultPattern defaultExpr))
       locationT
       where
         mkPattern = foldl (\pats (h, e) -> (Pattern (EnumPattern ((Map.!) locCons h)) e) : pats) []
         mkDefaultPattern e = [Pattern BottomPattern e]

     -- | Create the enum constructor for a given location name.
     locConsExpr :: Ord i => Map (LocationId i) (EnumConstr i) -> Type i -> LocationId i -> Expr i
     locConsExpr locNames t loc = mkTyped (AtExpr $ AtomEnum ((Map.!) locNames loc)) t

assertInits :: Ident i => StateInit i -> DeclM i ()
assertInits = mapM_ assertInit . Map.toList

assertInit :: Ident i => (i, ConstExpr i) -> DeclM i ()
assertInit (x, e) =
  do natAnn <- gets natImpl
     x' <- lookupVar x
     e' <- trConstExpr e
     let def = liftRel (.==.) (x' `appStream` (zero' natAnn)) e'
     liftSMT $ liftAssert def

-- | Creates a definition for a precondition p. If an activation condition c
-- is given, the resulting condition is (=> c p).
declarePrecond :: Ident i => Maybe (Stream Bool) -> Expr i -> DeclM i Definition
declarePrecond activeCond e =
  do env <- get
     d <- case activeCond of
       Nothing -> defStream boolT $ \t -> runTransM (trExpr e) env t
       Just c -> defStream boolT $
                 \t -> (flip (flip runTransM env) t)
                       (trExpr e >>= \e' -> return $ liftBool2 (.=>.) (BoolExpr $ c `app` t) e')
     return $ ensureDefinition d

declareInvariant :: Ident i => Maybe (Stream Bool) -> Expr i -> DeclM i Definition
declareInvariant = declarePrecond

trConstExpr :: Ident i => ConstExpr i -> DeclM i (TypedExpr i)
trConstExpr (untyped -> Const c) = return $ trConstant c
trConstExpr (untyped -> ConstEnum x) = lookupEnumConsAnn x >>= return . EnumExpr . trEnumConsAnn x
trConstExpr (untyped -> ConstProd (Prod cs)) =
  ProdExpr . listArray (0, length cs - 1) <$> mapM trConstExpr cs

type TransM i = ReaderT (StreamPos, Env i) (Either String)

doAppStream :: TypedStream i -> TransM i (TypedExpr i)
doAppStream s = askStreamPos >>= return . appStream s

-- beware: uses error
runTransM :: TransM i a -> Env i -> StreamPos -> a
runTransM m e n = case runReaderT m (n, e) of
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
  case untyped expr of
    AtExpr (AtomConst c) -> return $ trConstant c
    AtExpr (AtomVar x) ->
      do s <- lookupVar' x
         n <- askStreamPos
         return $ s `appStream` n
    AtExpr (AtomEnum x) -> EnumExpr <$> trEnumCons x
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
trPattern _ = error "Cannot match on non enum expression"

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
    trEnumHead c (EnumPattern e) = trEnumCons e >>= \y -> return $ liftRel (.==.) c (EnumExpr y)
    trEnumHead _ BottomPattern = return . BoolExpr $ constant True

trEnumConsAnn :: Ident i => EnumConstr i -> SMTAnnotation SMTEnum -> SMTExpr SMTEnum
trEnumConsAnn x = constantAnn (SMTEnum . fromString $ identString x)

trEnumCons :: Ident i => EnumConstr i -> TransM i (SMTExpr SMTEnum)
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
