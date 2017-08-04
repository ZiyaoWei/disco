{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveFoldable        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DeriveTraversable     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE UndecidableInstances  #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.AST.Surface
-- Copyright   :  (c) 2016 disco team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@gmail.com
--
-- Abstract syntax trees representing the surface syntax of the Disco
-- language.
--
-----------------------------------------------------------------------------

module Disco.AST.Surface
       ( -- * Modules
         Module(..), TopLevel(..)
         -- ** Documentation
       , Docs, DocMap, DocThing(..), Property
         -- ** Declarations
       , Decl(..), declName, isDefn

         -- * Operators
       , UOp(..), BOp(..), UFixity(..), BFixity(..), OpFixity(..)
       , OpInfo(..), opTable, uopMap, bopMap, uPrec, bPrec, funPrec

         -- * Terms
       , Side(..), Link(..)
       , Qual(..), Quals(..)
       , TyOp(..), Ellipsis(..), Term(..)

         -- * Case expressions and patterns
       , Branch, Guards(..), Guard(..), Pattern(..)
       )
       where

import           Data.Map                         (Map, (!))
import qualified Data.Map                         as M
import           GHC.Generics                     (Generic)

import           Unbound.Generics.LocallyNameless

import           Disco.Types

-- | A module is a list of declarations together with a collection of
--   documentation for top-level names.
data Module = Module [Decl] DocMap
  deriving Show

-- | A @TopLevel@ is either documentation (a 'DocThing') or a
--   declaration ('Decl').
data TopLevel = TLDoc DocThing | TLDecl Decl
  deriving Show

-- | Convenient synonym for a list of 'DocThing's.
type Docs = [DocThing]

-- | A 'DocMap' is a mapping from names to documentation.
type DocMap = Map (Name Term) Docs

-- | An item of documentation.
data DocThing
  = DocString     [String]      -- ^ A documentation string, i.e. a block of @||| text@ items
  | DocProperties [Property]    -- ^ A group of examples/properties of the form @!!! property@
  deriving Show

-- | A property is a universally quantified term of the form
--   @forall (v1 : T1) (v2 : T2). term@.
type Property = Bind [(Name Term, Type)] Term

-- | A declaration is either a type declaration or a definition.
data Decl where

  -- | A type declaration, @name : type@.
  DType :: Name Term -> Type -> Decl

  -- | A group of definition clauses of the form @name pat1 .. patn = term@. The
  --   patterns bind variables in the term. For example, @f n (x,y) =
  --   n*x + y@.
  DDefn :: Name Term -> [Bind [Pattern] Term] -> Decl
  deriving Show

-- | Get the name that a declaration is about.
declName :: Decl -> Name Term
declName (DType x _) = x
declName (DDefn x _) = x

-- | Check whether a declaration is a definition.
isDefn :: Decl -> Bool
isDefn DDefn{} = True
isDefn _       = False

-- | Injections into a sum type (@inl@ or @inr@) have a "side" (@L@ or @R@).
data Side = L | R
  deriving (Show, Eq, Enum, Generic)

-- | Unary operators.
data UOp = Neg   -- ^ Arithmetic negation (@-@)
         | Not   -- ^ Logical negation (@not@)
         | Fact  -- ^ Factorial (@!@)
         | Sqrt  -- ^ Integer square root (@sqrt@)
         | Lg    -- ^ Floor of base-2 logarithm (@lg@)
         | Floor -- ^ Floor of fractional type (@floor@)
         | Ceil  -- ^ Ceiling of fractional type (@ceiling@)
         | Abs   -- ^ Absolute value (@abs@)
  deriving (Show, Eq, Ord, Generic)

-- | Binary operators.
data BOp = Add     -- ^ Addition (@+@)
         | Sub     -- ^ Subtraction (@-@)
         | Mul     -- ^ Multiplication (@*@)
         | Div     -- ^ Division (@/@)
         | Exp     -- ^ Exponentiation (@^@)
         | IDiv    -- ^ Integer division (@//@)
         | Eq      -- ^ Equality test (@==@)
         | Neq     -- ^ Not-equal (@/=@)
         | Lt      -- ^ Less than (@<@)
         | Gt      -- ^ Greater than (@>@)
         | Leq     -- ^ Less than or equal (@<=@)
         | Geq     -- ^ Greater than or equal (@>=@)
         | And     -- ^ Logical and (@&&@ / @and@)
         | Or      -- ^ Logical or (@||@ / @or@)
         | Mod     -- ^ Modulo (@mod@)
         | Divides -- ^ Divisibility test (@|@)
         | RelPm   -- ^ Relative primality test (@#@)
         | Choose  -- ^ Binomial and multinomial coefficients (@choose@)
         | Cons    -- ^ List cons (@::@)
  deriving (Show, Eq, Ord, Generic)

-- | Fixities of unary operators (either pre- or postfix).
data UFixity
  = Pre     -- ^ Unary prefix.
  | Post    -- ^ Unary postfix.
  deriving (Eq, Ord, Enum, Bounded, Show, Generic)

-- | Fixity of infix binary operators (either left, right, or non-associative).
data BFixity
  = InL   -- ^ Left-associative infix.
  | InR   -- ^ Right-associative infix.
  | In    -- ^ Infix.
  deriving (Eq, Ord, Enum, Bounded, Show, Generic)

-- | Operators together with their fixity.
data OpFixity =
    UOpF UFixity UOp
  | BOpF BFixity BOp
  deriving (Eq, Show, Generic)

-- | An @OpInfo@ record contains information about an operator, such
--   as the operator itself, its fixity, a list of concrete syntax
--   representations of the operator, and a numeric precedence level.
data OpInfo =
  OpInfo
  { opFixity :: OpFixity
  , opSyns   :: [String]
  , opPrec   :: Int
  }
  deriving Show

-- | The @opTable@ lists all the operators in the language, in order
--   of precedence (highest precedence first).  Operators in the same
--   list have the same precedence.  This table is used by both the
--   parser and the pretty-printer.
opTable :: [[OpInfo]]
opTable =
  assignPrecLevels $
  [ [ uopInfo Pre  Not     ["not", "¬"]
    ]
  , [ uopInfo Pre  Neg     ["-"]
    ]
  , [ uopInfo Post Fact    ["!"]
    ]
  , [ bopInfo InR  Exp     ["^"]
    ]
  , [ uopInfo Pre  Sqrt    ["sqrt"]
    ]
  , [ uopInfo Pre  Lg      ["lg"]
    ]
  , [ uopInfo Pre  Floor   ["floor"]
    , uopInfo Pre  Ceil    ["ceiling"]
    , uopInfo Pre  Abs     ["abs"]
    ]
  , [ bopInfo In   Choose   ["choose"]
    ]
  , [ bopInfo InL  Mul     ["*"]
    , bopInfo InL  Div     ["/"]
    , bopInfo InL  Mod     ["%"]
    , bopInfo InL  Mod     ["mod"]
    , bopInfo InL  IDiv    ["//"]
    ]
  , [ bopInfo InL  Add     ["+"]
    , bopInfo InL  Sub     ["-"]
    ]
  , [ bopInfo InR  Cons    ["::"]
    ]
  , [ bopInfo InR  Eq      ["="]
    , bopInfo InR  Neq     ["/="]
    , bopInfo InR  Lt      ["<"]
    , bopInfo InR  Gt      [">"]
    , bopInfo InR  Leq     ["<="]
    , bopInfo InR  Geq     [">="]
    , bopInfo InR  Divides ["divides"]
    , bopInfo InR  RelPm   ["#"]
    ]
  , [ bopInfo InR  And     ["and", "∧", "&&"]
    ]
  , [ bopInfo InR  Or      ["or", "∨", "||"]
    ]
  ]
  where
    uopInfo fx op syns = OpInfo (UOpF fx op) syns (-1)
    bopInfo fx op syns = OpInfo (BOpF fx op) syns (-1)

    assignPrecLevels table = zipWith assignPrecs (reverse [1 .. length table]) table
    assignPrecs p ops      = map (assignPrec p) ops
    assignPrec  p op       = op { opPrec = p }

-- | A map from all unary operators to their associated 'OpInfo' records.
uopMap :: Map UOp OpInfo
uopMap = M.fromList $
  [ (op, info) | opLevel <- opTable, info@(OpInfo (UOpF _ op) _ _) <- opLevel ]

-- | A map from all binary operators to their associatied 'OpInfo' records.
bopMap :: Map BOp OpInfo
bopMap = M.fromList $
  [ (op, info) | opLevel <- opTable, info@(OpInfo (BOpF _ op) _ _) <- opLevel ]

-- | A convenient function for looking up the precedence of a unary operator.
uPrec :: UOp -> Int
uPrec = opPrec . (uopMap !)

-- | A convenient function for looking up the precedence of a binary operator.
bPrec :: BOp -> Int
bPrec = opPrec . (bopMap !)

-- | The precedence level of function application.
funPrec :: Int
funPrec = length opTable

-- | Type Operators
data TyOp = Enumerate -- List all values of a type
          | Count     -- Count how many values there are of a type
  deriving (Show, Eq, Generic)

-- | Terms.
data Term where

  -- | A variable.
  TVar   :: Name Term -> Term

  -- | Explicit parentheses.  We need to keep track of these in order
  --   to syntactically distinguish multiplication and function
  --   application.
  TParens :: Term -> Term

  -- | The unit value, (), of type Unit.
  TUnit  :: Term

  -- | True or false.
  TBool  :: Bool -> Term

  -- | An anonymous function.
  TAbs   :: Bind (Name Term) Term -> Term

     -- Note, could add an optional type annotation to TAbs,
     -- problem is I don't know what would be a good concrete syntax!
     -- x : Int -> body  is tricky because when parsing the type,
     -- the -> looks like a type arrow.  Could perhaps require
     -- parens i.e.  (x : Int) -> body ?

  -- | Function application.
  TApp  :: Term -> Term -> Term

  -- | An ordered pair, @(x,y)@.
  TTup   :: [Term] -> Term

  -- | An injection into a sum type.
  TInj   :: Side -> Term -> Term

  -- | A natural number.
  TNat   :: Integer -> Term

  -- | A nonnegative rational number, parsed as a decimal.
  TRat   :: Rational -> Term

  -- | An application of a unary operator.
  TUn    :: UOp -> Term -> Term

  -- | An application of a binary operator.
  TBin   :: BOp -> Term -> Term -> Term

  -- | An application of a type operator.
  TTyOp  :: TyOp -> Type -> Term

  -- | A chained comparison.  Should contain only comparison
  --   operators.
  TChain :: Term -> [Link] -> Term

  -- | A literal list.
  TList :: [Term] -> Maybe (Ellipsis Term) -> Term

  -- | List comprehension.
  TListComp :: Bind Quals Term -> Term

  -- | A (non-recursive) let expression, @let x = t1 in t2@.
  TLet   :: Bind (Name Term, Embed Term) Term -> Term

  -- | A case expression.
  TCase  :: [Branch] -> Term

  -- | Type ascription, @(term : type)@.
  TAscr  :: Term -> Type -> Term
  deriving (Show, Generic)

-- | An ellipsis is an "omitted" part of a literal list, of the form
--   @..@ or @.. t@.
data Ellipsis t where
  Forever ::      Ellipsis t   -- @..@
  Until   :: t -> Ellipsis t   -- @.. t@
  deriving (Show, Generic, Functor, Foldable, Traversable)

-- Note: very similar to guards
--  maybe some generalization in the future?
-- | A list of qualifiers in list comprehension.
--   Special type needed to record the binding structure.
data Quals where

  -- | The empty list of qualifiers
  QEmpty :: Quals

  -- | A qualifier followed by zero or more other qualifiers
  --   this qualifier can bind variables in the subsequent qualifiers.
  QCons  :: Rebind Qual Quals -> Quals

  deriving (Show, Generic)

-- | A single qualifier in a list comprehension.
data Qual where

  -- | A binding qualifier (i.e. @x <- t@)
  QBind   :: Name Term -> Embed Term -> Qual

  -- | A boolean guard qualfier (i.e. @x + y > 4@)
  QGuard  :: Embed Term -> Qual

  deriving (Show, Generic)

data Link where
  TLink :: BOp -> Term -> Link
  deriving (Show, Generic)

-- | A branch of a case is a list of guards with an accompanying term.
--   The guards scope over the term.  Additionally, each guard scopes
--   over subsequent guards.
type Branch = Bind Guards Term

-- | A list of guards.  Variables bound in each guard scope over
--   subsequent ones.
data Guards where

  -- | The empty list of guards, /i.e./ @otherwise@.
  GEmpty :: Guards

  -- | A single guard (@if@ or @when@) followed by more guards.
  GCons  :: Rebind Guard Guards -> Guards

  deriving (Show, Generic)

-- | A single guard in a branch: either an @if@ or a @when@.
data Guard where

  -- | Boolean guard (@if <test>@)
  GBool :: Embed Term -> Guard

  -- | Pattern guard (@when term = pat@)
  GPat  :: Embed Term -> Pattern -> Guard

  deriving (Show, Generic)

-- | Patterns.
data Pattern where

  -- | Variable pattern: matches anything and binds the variable.
  PVar  :: Name Term -> Pattern

  -- | Wildcard pattern @_@: matches anything.
  PWild :: Pattern

  -- | Unit pattern @()@: matches @()@.
  PUnit :: Pattern

  -- | Literal boolean pattern.
  PBool :: Bool -> Pattern

  -- | Tuple pattern @(pat1, .. , patn)@.
  PTup  :: [Pattern] -> Pattern

  -- | Injection pattern (@inl pat@ or @inr pat@).
  PInj  :: Side -> Pattern -> Pattern

  -- | Literal natural number pattern.
  PNat  :: Integer -> Pattern

  -- | Cons pattern @p1 :: p2@.
  PCons :: Pattern -> Pattern -> Pattern

  -- | List pattern @[p1, .., pn]@.
  PList :: [Pattern] -> Pattern

  -- | Arithmetic pattern like @3x + 1@.
  PArith :: Term -> Pattern

  deriving (Show, Generic)

instance Alpha Side
instance Alpha UOp
instance Alpha BOp
instance Alpha TyOp
instance Alpha Link
instance Alpha Term
instance Alpha t => Alpha (Ellipsis t)
instance Alpha Guards
instance Alpha Guard
instance Alpha Pattern
instance Alpha Quals
instance Alpha Qual

-- Names for terms can't show up in Rational, Pattern, or Type
instance Subst Term Rational where
  subst _ _ = id
  substs _  = id

-- Term does show up in PArith, but we don't need to substitute in it.
-- Any variables inside a PArith are actually supposed to be binders.
instance Subst Term Pattern where
  subst _ _ = id
  substs _  = id

instance Subst Term Type where
  subst _ _ = id
  substs _  = id

instance Subst Term Guards
instance Subst Term Guard
instance Subst Term Quals
instance Subst Term Qual
instance Subst Term Side
instance Subst Term BOp
instance Subst Term UOp
instance Subst Term TyOp
instance Subst Term Link
instance Subst Term (Ellipsis Term)
instance Subst Term Term where
  isvar (TVar x) = Just (SubstName x)
  isvar _ = Nothing
