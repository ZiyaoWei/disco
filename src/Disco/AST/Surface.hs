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
         Module, Decl(..), declName, isDefn

         -- * Terms
       , Side(..), UOp(..), BOp(..)
       , Term(..)

         -- * Case expressions and patterns
       , Branch, Guards(..), Guard(..), Pattern(..), PArithOp(..)
       )
       where

import           Unbound.LocallyNameless

import           Disco.Types

-- | A module is a list of declarations.
type Module = [Decl]

-- | A declaration is either a type declaration or a definition.
data Decl where

  -- | A type declaration, @name : type@.
  DType :: Name Term -> Type -> Decl

  -- | A definition, @name pat1 .. patn = term@. The patterns bind
  --   variables in the term. For example,  @f n (x,y) = n*x + y@.
  DDefn :: Name Term -> Bind [Pattern] Term -> Decl
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
  deriving (Show, Eq, Enum)

-- | Unary operators.
data UOp = Neg   -- ^ Arithmetic negation (@-@)
         | Not   -- ^ Logical negation (@not@)
         | Fact  -- ^ Factorial (@!@)
  deriving (Show, Eq)

-- | Binary operators.
data BOp = Add     -- ^ Addition (@+@)
         | Sub     -- ^ Subtraction (@-@)
         | Mul     -- ^ Multiplication (@*@)
         | Div     -- ^ Division (@/@)
         | Exp     -- ^ Exponentiation (@^@)
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
         | Binom   -- ^ Binomial coefficient (@binom@)
         | Cons    -- ^ List cons (@::@)
  deriving (Show, Eq)

-- XXX todo add TRat with ability to parse decimal notation

-- | Terms.
data Term where

  -- | A variable.
  TVar   :: Name Term -> Term

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

  -- | Juxtaposition (can be either function application or
  --   multiplication).
  TJuxt  :: Term -> Term -> Term

  -- | An ordered pair, @(x,y)@.
  TPair  :: Term -> Term -> Term

  -- | An injection into a sum type.
  TInj   :: Side -> Term -> Term

  -- | A natural number.
  TNat   :: Integer -> Term

  -- | An application of a unary operator.
  TUn    :: UOp -> Term -> Term

  -- | An application of a binary operator.
  TBin   :: BOp -> Term -> Term -> Term

  -- | A literal list.
  TList :: [Term] -> Term

  -- | A (non-recursive) let expression, @let x = t1 in t2@.
  TLet   :: Bind (Name Term, Embed Term) Term -> Term

  -- | A case expression.
  TCase  :: [Branch] -> Term

  -- | Type ascription, @(term : type)@.
  TAscr  :: Term -> Type -> Term
  deriving Show

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

  deriving Show

-- | A single guard in a branch: either an @if@ or a @when@.
data Guard where

  -- | Boolean guard (@if <test>@)
  GIf   :: Embed Term -> Guard

  -- | Pattern guard (@when term = pat@)
  GWhen :: Embed Term -> Pattern -> Guard

  deriving Show

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

  -- | Pair pattern @(pat1, pat2)@.
  PPair :: Pattern -> Pattern -> Pattern

  -- | Injection pattern (@inl pat@ or @inr pat@).
  PInj  :: Side -> Pattern -> Pattern

  -- | Literal natural number pattern.
  PNat  :: Integer -> Pattern

  -- | Successor pattern, @S p@.
  PSucc :: Pattern -> Pattern

  -- | Cons pattern @p1 :: p2@.
  PCons :: Pattern -> Pattern -> Pattern

  -- | List pattern @[p1, .., pn]@.
  PList :: [Pattern] -> Pattern

  -- | Negation pattern @-p@.
  PNeg :: Pattern -> Pattern

  -- | Arithmetic pattern, like @x+1@ or @2/3@ or @2x + 2@.
  PArith :: PArithOp -> Pattern -> Pattern -> Pattern

  deriving Show

-- | Arithmetic operators that can appear in patterns.
data PArithOp = PAdd | PSub | PMul | PDiv
  deriving Show

derive [''Side, ''UOp, ''BOp, ''Term, ''Guards, ''Guard, ''Pattern, ''PArithOp]

instance Alpha Side
instance Alpha UOp
instance Alpha BOp
instance Alpha Term
instance Alpha Guards
instance Alpha Guard
instance Alpha Pattern
instance Alpha PArithOp

instance Subst Term Type
instance Subst Term Guards
instance Subst Term Guard
instance Subst Term Pattern
instance Subst Term PArithOp
instance Subst Term Side
instance Subst Term BOp
instance Subst Term UOp
instance Subst Term Term where
  isvar (TVar x) = Just (SubstName x)
  isvar _ = Nothing
