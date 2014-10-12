{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE RankNTypes        #-}

-- Module      : Text.EDE.Internal.Parser
-- Copyright   : (c) 2013-2014 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Text.EDE.Internal.Parser
    ( Includes
    , runParser
    ) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.State.Strict
import           Data.Bifunctor
import           Data.ByteString            (ByteString)
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as Map
import           Data.List.NonEmpty         (NonEmpty(..))
import qualified Data.List.NonEmpty         as NonEmpty
import           Data.Scientific
import           Data.Semigroup
import           Data.Text                  (Text)
import qualified Data.Text                  as Text
import qualified Data.Text.Encoding         as Text
import           Text.EDE.Internal.AST
import           Text.EDE.Internal.Syntax
import           Text.EDE.Internal.Types
import           Text.Parser.Expression
import           Text.Parser.LookAhead
import qualified Text.Trifecta              as Tri
import           Text.Trifecta              hiding (Result(..), render)
import           Text.Trifecta.Delta

-- FIXME: add 'raw' tag
-- whitespace
-- comments

type Includes = HashMap Text (NonEmpty Delta)

data Env = Env
    { _options  :: !Options
    , _includes :: Includes
    }

makeLenses ''Env

type Parse m =
    ( Monad m
    , MonadState Env m
    , TokenParsing m
    , DeltaParsing m
    , LookAheadParsing m
    )

runParser :: Options -> Text -> ByteString -> Result (Exp, Includes)
runParser o n = res . parseByteString (runStateT (document <* eof) env) pos
  where
    env = Env o mempty
    pos = Directed (Text.encodeUtf8 n) 0 0 0 0

    res (Tri.Success x) = Success (_includes `second` x)
    res (Tri.Failure e) = Failure e

document :: Parse m => m Exp
document = eapp <$> position <*> many expr
  where
    expr = choice
        [ render
        , ifelif
        , cases
        , loop
        , include
        , binding
        , fragment
        ]

render :: Parse m => m Exp
render = between renderStart renderEnd term

fragment :: Parse m => m Exp
fragment = notFollowedBy anyStart >> ELit
    <$> position
    <*> (LText . Text.pack <$> manyTill1 anyChar (lookAhead anyStart <|> eof))

ifelif :: Parse m => m Exp
ifelif = eif
    <$> branch "if"
    <*> many (branch "elif")
    <*> else'
    <*  end "endif"
  where
    branch k = (,) <$> block k term <*> document

cases :: Parse m => m Exp
cases = ecase
    <$> block "case" term
    <*> many
        ((,) <$> block "when" pattern
             <*> document)
    <*> else'
    <*  end "endcase"

loop :: Parse m => m Exp
loop = do
    d <- position
    uncurry (ELoop d)
        <$> block "for"
            ((,) <$> identifier
                 <*> (keyword "in" *> variable))
        <*> document
        <*> else'
        <*  end "endfor"

include :: Parse m => m Exp
include = do
    d <- position
    block "include" $ do
        k <- stringLiteral
        includes %= Map.insertWith (<>) k (d:|[])
        EIncl d k <$> optional (keyword "with" *> term)

binding :: Parse m => m Exp
binding = do
    d <- position
    uncurry (ELet d)
        <$> block "let"
            ((,) <$> identifier
                 <*> (symbol "=" *> term))
        <*> document
        <*  end "endlet"

block :: Parse m => String -> m a -> m a
block k = between (try (blockStart *> keyword k)) blockEnd

else' :: Parse m => m (Maybe Exp)
else' = optional (block "else" (pure ()) *> document)

end :: Parse m => String -> m ()
end k = block k (pure ())

term :: Parse m => m Exp
term = buildExpressionParser table expr
  where
    table =
        [ [prefix "!"]
        , [infix' "*", infix' "/"]
        , [infix' "-", infix' "+"]
        , [infix' "==", infix' "!=", infix' ">", infix' ">=", infix' "<", infix' "<="]
        , [infix' "&&"]
        , [infix' "||"]
        , [filter' "|"]
        ]

    prefix n = Prefix (efun <$> operator n <*> pure n)

    infix' n = Infix (do
        d <- operator n
        return $ \l r ->
            EApp d (efun d n l) r) AssocLeft

    filter' n = Infix (do
        d <- operator n
        i <- try (lookAhead identifier)
        return $ \l _ ->
            efun d i l) AssocLeft

    expr = parens term <|> apply EVar variable <|> apply ELit literal

pattern :: Parse m => m Pat
pattern = PWild <$ char '_' <|> PVar <$> variable <|> PLit <$> literal

literal :: Parse m => m Lit
literal = LBool <$> boolean <|> LNum <$> number <|> LText <$> stringLiteral

number :: Parse m => m Scientific
number = either fromIntegral fromFloatDigits <$> integerOrDouble

boolean :: Parse m => m Bool
boolean = symbol "true " *> return True
      <|> symbol "false" *> return False

operator :: Parse m => Text -> m Delta
operator n = position <* reserveText operatorStyle n

keyword :: Parse m => String -> m Delta
keyword k = position <* try (reserve keywordStyle k)

variable :: Parse m => m Var
variable = Var <$> (NonEmpty.fromList <$> sepBy1 identifier (char '.'))

identifier :: Parse m => m Id
identifier = ident variableStyle

manyTill1 :: (Monad m, Alternative m) => m a -> m b -> m [a]
manyTill1 p e = liftM2 (:) p (manyTill p e)

apply :: Parse m => (Delta -> a -> b) -> m a -> m b
apply f p = f <$> position <*> p

anyStart :: Parse m => m ()
anyStart = void . try $ choice
    [ renderStart
    , commentStart
    , blockStart
    ]

renderStart, commentStart, blockStart :: Parse m => m ()
renderStart  = config (delimRender._1)  >>= void . symbol
commentStart = config (delimComment._1) >>= void . symbol
blockStart   = config (delimBlock._1)   >>= void . symbol

renderEnd, commentEnd, blockEnd :: Parse m => m ()
renderEnd  = config (delimRender._2)  >>= void . string
commentEnd = config (delimComment._2) >>= void . string
blockEnd   = config (delimBlock._2)   >>= void . string

config :: MonadState Env m => Getter Options a -> m a
config l = gets (view (options.l))
