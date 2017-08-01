{-# LANGUAGE FlexibleContexts, DeriveFunctor, TypeOperators, TypeFamilies #-}
module Lib ( parse
           , Term (..)
           , AST
           , State (..)
           , simulateUnsafe
           , expect
           , send
           , Value (..)
           , Error (..)
           , repl
           ) where

import Text.Parsec ( many1
                   , alphaNum
                   , Parsec
                   , (<|>)
                   , between
                   , spaces
                   , sepEndBy
                   , many
                   , option
                   , eof
                   , oneOf
                   )
import qualified Text.Parsec as P
import Text.Parsec.Char ( char, letter, digit )
import Data.Bifunctor
import qualified Data.Map.Lazy as M
import Control.Eff hiding ( send, run )
import qualified Control.Eff as E
import Control.Eff.Exception
import Control.Eff.Lift
import Control.Exception ( Exception, throw )
import Data.Void
import Prelude hiding ( lookup, print )
import Data.Foldable (traverse_)
import Data.Typeable
import Data.List (intercalate)
import Data.OpenUnion (weaken)
import System.IO (hSetBuffering, BufferMode(NoBuffering), stdout)

data Term = Word Name | Quoted AST | Number Int
    deriving (Eq, Show)
type Name = String
type AST = [Term]

prettyAST :: AST -> String
prettyAST = intercalate " " . map prettyTerm
    where
        prettyTerm (Word n) = n
        prettyTerm (Number n) = show n
        prettyTerm (Quoted a) = "[" ++ prettyAST a ++ "]"

parse :: String -> Either String AST
parse = first show . P.parse (ast <* eof) "parsing silly-joy"

ast :: Parsec String st AST
ast = spaces >> term `sepEndBy` spaces

term :: Parsec String st Term
term = word <|> quoted <|> number

word :: Parsec String st Term
word = do
    l <- letter <|> oneOf ['+']
    ans <- many alphaNum
    return . Word $ l : ans

number :: Parsec String st Term
number = do
    sign <- option 1 (char '-' >> spaces >> return (-1))
    n <- many1 digit
    return $ Number (sign * (read n))

quoted :: Parsec String st Term
quoted = Quoted <$> between (char '[') (char ']') ast


data Value = P Program AST | I Int

instance Eq Value where
    (P _ a) == (P _ a') | a == a' = True
    (I i) == (I i') | i == i' = True
    _ == _ = False

instance Show Value where
    show (I i) = show i
    show (P _ s) = "[" ++ prettyAST s ++ "]"


data StateEffect v = Push Value v
                   | Pop (Value -> v)
                   | Lookup Name (Program -> v)
    deriving ( Functor )

data RealWorldEffect v = Print String v | Input (String -> v)
    -- TODO: Maybe extend Input Int to Input Value and interpret string
    deriving ( Functor )

data Error = Undefined Name | PoppingEmptyStack | TypeMismatch
    deriving ( Show, Eq )

instance Exception Error

type Program = Eff (StateEffect :> (Exc Error) :> RealWorldEffect :> Void) ()

data State = State { stack :: [Value]
                   , dict :: M.Map Name Program
                   }

lookup :: Member StateEffect e => Name -> Eff e Program
lookup n = E.send . inj $ Lookup n id

push :: Member StateEffect e => Value -> Eff e ()
push v = E.send . inj $ Push v ()

pop :: Member StateEffect e => Eff e Value
pop = E.send . inj $ Pop id

print :: Member RealWorldEffect e => String -> Eff e ()
print s = E.send . inj $ Print s ()

initialDictionary :: M.Map Name Program
initialDictionary = M.fromList
    [ ("pop", pop >> return ())
    , ("i", pop >>= castProgram >>= id)
    , ("dup", do v <- pop; push v; push v)
    , ("dip", do v <- pop; pop >>= castProgram >>= id; push v)
    , ("+", do a <- pop >>= castInt; b <- pop >>= castInt; push (I $ a + b))
    , ("print", pop >>= print . show)
    ]

initialState :: State
initialState = State { stack = [], dict = initialDictionary }

castProgram :: Member (Exc Error) e => Value -> Eff e Program
castProgram (P p _) = return p
castProgram _ = throwExc TypeMismatch

castInt :: Member (Exc Error) e => Value -> Eff e Int
castInt (I i) = return i
castInt _ = throwExc TypeMismatch

interpret :: AST -> Program
interpret [] = return ()
interpret ((Word n):ts) = lookup n >>= id >> interpret ts
interpret ((Quoted a):ts) = push (P (interpret a) a) >> interpret ts
interpret ((Number n):ts) = push (I n) >> interpret ts

runStateEffect :: Member (Exc Error) e => State -> Eff (StateEffect :> e) v
               -> Eff e (State, v)
runStateEffect state = freeMap (\x -> return (state, x))
    (\u -> handleRelay u (runStateEffect state) (handle state))
        where
        handle s (Push v k) =
            let s' = s { stack = v : stack s } in runStateEffect s' k

        handle (s@State { stack = v : st }) (Pop k) =
            runStateEffect (s { stack = st }) (k v)

        handle (State { stack = [] }) (Pop _) =
            throwExc PoppingEmptyStack

        handle (s@State { dict = d }) (Lookup n k) =
            case M.lookup n d of
              Just p -> runStateEffect s (k p)
              Nothing -> throwExc $ Undefined n

data SimulatedIO = ExpectOutput String | SendInput String

send :: String -> SimulatedIO
send = SendInput

expect :: String -> SimulatedIO
expect = ExpectOutput

data SimulatedIOError = UnexpectedOutput String
                      | IncorrectOutput String String
                      | UnexpectedInput
                      | EndOfExpectations
                      deriving ( Show )

instance Exception SimulatedIOError

simulateRealWorld :: [SimulatedIO] -> Eff (RealWorldEffect :> e) v -> Eff e v
simulateRealWorld expects = freeMap return
    (\u -> handleRelay u (simulateRealWorld expects) (handle expects))
        where
            handle [] _ = throw EndOfExpectations
            handle (ExpectOutput o : exs) (Print o' k)
              | o == o' = simulateRealWorld exs k
              | otherwise = throw $ IncorrectOutput o o'

            handle (SendInput i : exs) (Input k) =
                simulateRealWorld exs (k i)

            handle (SendInput _ : _) (Print o _) =
                throw $ UnexpectedOutput o

            handle (ExpectOutput _ : _) (Input _) =
                throw $ UnexpectedInput

simulateUnsafe :: String -> [SimulatedIO] -> State
simulateUnsafe s exs =
    let parsed = either error id $ parse s in
    let p = interpret parsed in
    let (st, ()) = either throw id . E.run .
                    simulateRealWorld exs . runExc $
                        runStateEffect initialState p in
        st

runRealWorld :: Eff (RealWorldEffect :> e) v -> Eff (Lift IO :> e) v
runRealWorld = freeMap return (\u -> transform u runRealWorld handle)
    where
        handle :: RealWorldEffect (Eff (RealWorldEffect :> e) w)
               -> Eff (Lift IO :> e) w
        handle (Print s k) = lift (putStrLn s) >> runRealWorld k
        handle (Input k) = lift getLine >>= runRealWorld . k

transform :: (Typeable t, Typeable s, Functor s)
          => Union (t :> r) v -- ^ Request
          -> (v -> Eff (s :> r) a)   -- ^ Relay the request
          -> (t v -> Eff (s :> r) a) -- ^ Handle the request of type t
          -> Eff (s :> r) a
transform u loop h = either passOn h $ decomp u
    where
        passOn u' = E.send (weaken u') >>= loop

repl :: IO ()
repl = do
    hSetBuffering stdout NoBuffering
    loop initialState
    where
        loop s = do
            putStr "> "
            raw <- getLine
            case raw of
              ':' : 's' : _ -> dumpStack s
              _ -> doParsing raw s

        dumpStack s =
            traverse_ (putStrLn . show) (stack s) >> loop s

        doParsing raw s =
            case parse raw of
              Right parsed -> do
                  let p = interpret parsed
                  x <- runLift . runRealWorld . runExc $ runStateEffect s p
                  case x of
                    Right (s', ()) -> loop s'
                    Left e -> (putStrLn . show $ e) >> loop s
              Left e -> putStrLn e >> loop s
