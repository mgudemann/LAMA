module Lang.LAMA.Structure.PosIdentUntyped (
  module Lang.LAMA.Structure,
  Program,
  -- * Type definitions
  TypeDef,
  -- ** Enums
  EnumConstr, EnumT,
  -- ** Records
  RecordField, RecordT,
  -- * Constants
  Constant,
  -- * Nodes
  Node, Variable,
  Declarations,
  -- * Data flow
  Flow,
  -- ** Definition of local and output variables
  Pattern, InstantDefinition, Instant,
  -- ** Definition of state variables
  StateTransition, StateInit,
  -- * Automata
  LocationId, Location, Edge, Automaton,
  -- * Expressions
  Atom, Expr, ConstExpr,
  -- * Constructors
  boolConst, constAtExpr,
  module Lang.LAMA.Fix
) where

import Lang.LAMA.Identifier
import qualified Lang.LAMA.UnTypedStructure as S
import Lang.LAMA.Structure
import Lang.LAMA.UnTypedStructure (boolConst, constAtExpr)
import Lang.LAMA.Fix

type Constant = S.Constant
type Expr = S.Expr PosIdent
type Atom = S.Atom PosIdent
type ConstExpr = S.ConstExpr PosIdent

type Program = S.Program PosIdent
type Node = S.Node PosIdent
type Declarations = S.Declarations PosIdent
type Flow = S.Flow PosIdent
type InstantDefinition = S.InstantDefinition PosIdent
type Instant = S.Instant PosIdent
type StateTransition = S.StateTransition PosIdent
type StateInit = S.StateInit PosIdent
type Location = S.Location PosIdent
type Edge = S.Edge PosIdent
type Automaton = S.Automaton PosIdent

type TypeDef = S.TypeDef PosIdent
type EnumConstr = S.EnumConstr PosIdent
type EnumT = S.EnumT PosIdent
type RecordField = S.RecordField PosIdent
type RecordT = S.RecordT PosIdent
type Variable = S.Variable PosIdent
type Pattern = S.Pattern PosIdent
type LocationId = S.LocationId PosIdent