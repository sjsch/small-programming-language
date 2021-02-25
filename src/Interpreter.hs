{-# LANGUAGE RecursiveDo #-}

module Interpreter where

import Control.Monad.Except
import Control.Monad.State
import Data.IORef
import qualified Data.Map as M
import Syntax

newtype Env = Env (M.Map Ident Value)

-- | An immutable value at runtime.  Variables bind to these directly:
-- assigning to a variable changes which value it points to.  (If you
-- pass a value to a function, it is "copied" in.)
data Value
  = ValueNumber Double
  | ValueBool Bool
  | -- | A closure.  When you evaluate a functione expression, it
    -- | closes over its local envinrionment and returns it in one of
    -- | these (lexical scope).
    ValueClosure Env [Ident] Block
  | ValueNull
  | -- | A reference to an object on the heap.  This is for variables
    -- | that refer to things that can be mutated, like arrays or
    -- | dictionaries.  When you pass a reference into a function, the
    -- | reference is copied, but the object that it points to is not.
    -- | Assigning to a dictionary/array access expression mutates the
    -- | object pointed to by the reference.
    ValueRef (IORef Object)
  | -- | A builtin value, like print.
    ValuePrim Prim

-- | An object on the heap.  Functions that modify objects can write
-- to the IORef pointing to us.
data Object
  = ObjectArray [Value]

-- | A built-in value, like the print function.
data Prim
  = PrimPrint

-- | Mappings from variable names to built-in functions.  Programs get
-- these bindings in their environment when they start.
initialEnv :: Env
initialEnv =
  Env $
    M.fromList
      [ ("print", ValuePrim PrimPrint)
      ]

data VType
  = VTypeNumber
  | VTypeBool
  | VTypeClosure
  | VTypeNull
  | VTypePrim
  deriving (Show)

data Error
  = ErrLookup Ident
  | ErrType VType VType
  | ErrArgs Int Int
  deriving (Show)

type Interpreter a = StateT Env (ExceptT Error IO) a

testBlock :: Block
testBlock = [StmtWhile (ExprBool False) []]

testInterpret :: Block -> IO (Either Error Value)
testInterpret b = runExceptT (evalStateT (evalBlock b) initialEnv)

apply :: Env -> [Ident] -> Block -> [Value] -> Interpreter Value
apply (Env env) params body args
  | length params /= length args =
    throwError
      (ErrArgs (length params) (length args))
  | otherwise = do
    let argBinds = M.fromList (zip params args)
        env' = Env (argBinds `M.union` env)
    lift (evalStateT (evalBlock body) env')

evalBlock :: Block -> Interpreter Value
evalBlock [] = pure ValueNull
evalBlock (s@(StmtReturn _) : _) = evalStmt s
evalBlock [stmt] = evalStmt stmt
evalBlock (stmt : stmts) = evalStmt stmt >> evalBlock stmts

evalStmt :: Stmt -> Interpreter Value
evalStmt s@(StmtWhile condition conditional) = do
  conditionValue <- evalExpr condition
  conditionBool <- checkBool conditionValue
  if conditionBool
    then evalBlock conditional >> evalStmt s
    else pure ValueNull
evalStmt (StmtExpr e) = evalExpr e
evalStmt (StmtAssign v e) = mdo
  modify (\(Env m) -> Env (M.insert v e' m))
  e' <- evalExpr e
  pure ValueNull
evalStmt (StmtReturn Nothing) = pure ValueNull
evalStmt (StmtReturn (Just r)) = evalExpr r

evalExpr :: Expr -> Interpreter Value
evalExpr (ExprVariable v) = do
  Env m <- get
  maybe (throwError (ErrLookup v)) pure (M.lookup v m)
evalExpr (ExprNumber n) = pure (ValueNumber n)
evalExpr (ExprBool n) = pure (ValueBool n)
evalExpr (ExprBinop op x y) = do
  x' <- evalExpr x
  y' <- evalExpr y
  evalBinop op x' y'
evalExpr (ExprCall f as) = do
  f' <- evalExpr f
  as' <- traverse evalExpr as
  case f' of
    ValueClosure env params body -> apply env params body as'
    ValuePrim p -> evalPrim p as'
    _ -> throwError (ErrType VTypeClosure (valueType f'))
evalExpr (ExprFunc ps body) = do
  env <- get
  pure (ValueClosure env ps body)
evalExpr (ExprArray exprs) = do
  exprs' <- traverse evalExpr exprs
  undefined
evalExpr (ExprIfElseChain [] Nothing) = pure ValueNull
evalExpr (ExprIfElseChain [] (Just els)) = evalBlock els
evalExpr (ExprIfElseChain ((cond, body) : xs) els) = do
  conditionValue <- evalExpr cond
  conditionBool <- checkBool conditionValue
  if conditionBool
    then evalBlock body
    else evalExpr (ExprIfElseChain xs els)

evalPrim :: Prim -> [Value] -> Interpreter Value
evalPrim PrimPrint as = do
  strs <- traverse showValue as
  liftIO (putStrLn (concat strs))
  pure ValueNull

evalBinop :: Binop -> Value -> Value -> Interpreter Value
evalBinop BinopPlus x y = do
  x' <- checkNumber x
  y' <- checkNumber y
  pure (ValueNumber (x' + y'))

showValue :: Value -> Interpreter String
showValue (ValueNumber n) = pure (show n)
showValue (ValueBool b) = pure (if b then "true" else "false")
showValue (ValueClosure _ _ _) = pure "<closure>"
showValue ValueNull = pure "null"
showValue (ValuePrim p) = pure "<primitive>"

checkNumber :: Value -> Interpreter Double
checkNumber (ValueNumber n) = pure n
checkNumber v = throwError (ErrType VTypeNumber (valueType v))

checkBool :: Value -> Interpreter Bool
checkBool (ValueBool n) = pure n
checkBool v = throwError (ErrType VTypeBool (valueType v))

valueType :: Value -> VType
valueType (ValueNumber _) = VTypeNumber
valueType ValueClosure {} = VTypeClosure
valueType ValueNull = VTypeNull
valueType (ValuePrim _) = VTypePrim
