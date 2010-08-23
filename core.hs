{-
 - skim-scheme interpreter
 -
 - A lightweight dialect of R5RS scheme.
 - Core functionality
 -
 - @author Justin Ethier
 -
 - -}

{-
 - TODO: 
 -
 - => compare my functions against those listed on 
 -    http://en.wikipedia.org/wiki/Scheme_(programming_language)
 -
 - => think about how to implement hashtable in scheme 
 -    (http://www.math.grin.edu/~stone/events/scheme-workshop/hash-tables.html)
 -
 - -}

module Main where
import Control.Monad
import Control.Monad.Error
import Char
import Data.Array
import Data.IORef
import Maybe
import List
import IO hiding (try)
import Numeric
import System.Environment
import Text.ParserCombinators.Parsec hiding (spaces)

main :: IO ()
main = do args <- getArgs
          if null args then runRepl else runOne $ args

-- REPL Section
flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

evalString :: Env -> String -> IO String
evalString env expr = runIOThrows $ liftM show $ (liftThrows $ readExpr expr) >>= macroEval env >>= eval env

evalAndPrint :: Env -> String -> IO ()
evalAndPrint env expr = evalString env expr >>= putStrLn

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ pred prompt action = do
  result <- prompt
  if pred result
     then return ()
     else action result >> until_ pred prompt action

runOne :: [String] -> IO ()
runOne args = do
-- TODO: hook into macroEval (probably at a lower level, though)
  env <-primitiveBindings >>= flip bindVars [((varNamespace, "args"), List $ map String $ drop 1 args)]
  (runIOThrows $ liftM show $ eval env (List [Atom "load", String (args !! 0)]))
     >>= hPutStrLn stderr  -- TODO: echo this or not??

  -- Call into (main) if it exists...
  alreadyDefined <- liftIO $ isBound env "main"
  let argv = List $ map String $ args
  if alreadyDefined
     then (runIOThrows $ liftM show $ eval env (List [Atom "main", List [Atom "quote", argv]])) >>= hPutStrLn stderr
     else (runIOThrows $ liftM show $ eval env $ Nil "") >>= hPutStrLn stderr

runRepl :: IO ()
runRepl = primitiveBindings >>= until_ (== "quit") (readPrompt "skim> ") . evalAndPrint

-- End REPL Section
readOrThrow :: Parser a -> String -> ThrowsError a
readOrThrow parser input = case parse parser "lisp" input of
	Left err -> throwError $ Parser err
	Right val -> return val

readExpr = readOrThrow parseExpr
readExprList = readOrThrow (endBy parseExpr spaces)

{- Variables Section -}
type Env = IORef [((String, String), IORef LispVal)] -- lookup via: (namespace, variable)
type IOThrowsError = ErrorT LispError IO

nullEnv :: IO Env
nullEnv = newIORef []

liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left err) = throwError err
liftThrows (Right val) = return val

runIOThrows :: IOThrowsError String -> IO String
runIOThrows action = runErrorT (trapError action) >>= return . extractValue


macroNamespace = "m"
varNamespace = "v"

-- Determine if a variable is bound in the "variable" namespace
isBound :: Env -> String -> IO Bool
isBound envRef var = isNamespacedBound envRef varNamespace var

-- Determine if a variable is bound in the given namespace
isNamespacedBound :: Env -> String -> String -> IO Bool
isNamespacedBound envRef namespace var = readIORef envRef >>= return . maybe False (const True) . lookup (namespace, var)

getVar :: Env -> String -> IOThrowsError LispVal
getVar envRef var = getNamespacedVar envRef varNamespace var

getNamespacedVar :: Env -> String -> String -> IOThrowsError LispVal
getNamespacedVar envRef
                 namespace
                 var = do env <- liftIO $ readIORef envRef
                          maybe (throwError $ UnboundVar "Getting an unbound variable" var)
                                (liftIO . readIORef)
                                (lookup (namespace, var) env)

setVar, defineVar :: Env -> String -> LispVal -> IOThrowsError LispVal
setVar envRef var value = setNamespacedVar envRef varNamespace var value
defineVar envRef var value = defineNamespacedVar envRef varNamespace var value

setNamespacedVar :: Env -> String -> String -> LispVal -> IOThrowsError LispVal
setNamespacedVar envRef 
                 namespace
                 var value = do env <- liftIO $ readIORef envRef
                                maybe (throwError $ UnboundVar "Setting an unbound variable: " var)
                                      (liftIO . (flip writeIORef value))
                                      (lookup (namespace, var) env)
                                return value

defineNamespacedVar :: Env -> String -> String -> LispVal -> IOThrowsError LispVal
defineNamespacedVar envRef 
                    namespace 
                    var value = do
  alreadyDefined <- liftIO $ isNamespacedBound envRef namespace var
  if alreadyDefined
    then setNamespacedVar envRef namespace var value >> return value
    else liftIO $ do
       valueRef <- newIORef value
       env <- readIORef envRef
       writeIORef envRef (((namespace, var), valueRef) : env)
       return value

bindVars :: Env -> [((String, String), LispVal)] -> IO Env
bindVars envRef bindings = readIORef envRef >>= extendEnv bindings >>= newIORef
  where extendEnv bindings env = liftM  (++ env) (mapM addBinding bindings)
        addBinding (var, value) = do ref <- newIORef value
                                     return (var, ref)

{- Error handling code -}
data LispError = NumArgs Integer [LispVal]
  | TypeMismatch String LispVal
  | Parser ParseError
  | BadSpecialForm String LispVal
  | NotFunction String String
  | UnboundVar String String
  | Default String

showError :: LispError -> String
showError (NumArgs expected found) = "Expected " ++ show expected
                                  ++ " args; found values " ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected
                                  ++ ", found " ++ show found
showError (Parser parseErr) = "Parse error at " ++ ": " ++ show parseErr
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func) = message ++ ": " ++ show func
showError (UnboundVar message varname) = message ++ ": " ++ varname

instance Show LispError where show = showError
instance Error LispError where
  noMsg = Default "An error has occurred"
  strMsg = Default

type ThrowsError = Either LispError

trapError action = catchError action (return . show)

extractValue :: ThrowsError a -> a
extractValue (Right val) = val

data LispVal = Atom String
	| List [LispVal]
	| DottedList [LispVal] LispVal
	| Vector (Array Int LispVal)
	| Number Integer
	| Float Float
 	| String String
	| Char Char
	| Bool Bool
	| PrimitiveFunc ([LispVal] -> ThrowsError LispVal)
	| Func {params :: [String], vararg :: (Maybe String),
	        body :: [LispVal], closure :: Env}
	| IOFunc ([LispVal] -> IOThrowsError LispVal)
	| Port Handle
    | Nil String -- String is probably wrong type here, but OK for now (do not expect to use this much, just internally)

showVal :: LispVal -> String
showVal (Nil _) = ""
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Char chr) = [chr]
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Float contents) = show contents
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (Vector contents) = "#(" ++ (unwordsList $ Data.Array.elems contents) ++ ")"
showVal (List contents) = "(" ++ unwordsList contents ++ ")"
showVal (DottedList head tail) = "(" ++ unwordsList head ++ " . " ++ showVal tail ++ ")"
showVal (PrimitiveFunc _) = "<primitive>"
showVal (Func {params = args, vararg = varargs, body = body, closure = env}) = 
  "(lambda (" ++ unwords (map show args) ++
    (case varargs of
      Nothing -> ""
      Just arg -> " . " ++ arg) ++ ") ...)"
showVal (Port _) = "<IO port>"
showVal (IOFunc _) = "<IO primitive>"

unwordsList :: [LispVal] -> String
unwordsList = unwords . map showVal

{- Allow conversion of lispval instances to strings -}
instance Show LispVal where show = showVal

symbol :: Parser Char
symbol = oneOf "!$%&|*+-/:<=>?@^_~" -- TODO: I removed #, make sure this is OK w/spec, and test cases

spaces :: Parser ()
spaces = skipMany1 space

parseAtom :: Parser LispVal
parseAtom = do
	first <- letter <|> symbol <|> (oneOf ".")
	rest <- many (letter <|> digit <|> symbol <|> (oneOf "."))
	let atom = first:rest
	if atom == "."
           then pzero -- Do not match this form
           else return $ Atom atom

parseBool :: Parser LispVal
parseBool = do string "#"
               x <- oneOf "tf"
               return $ case x of
                          't' -> Bool True
                          'f' -> Bool False

parseChar :: Parser LispVal
parseChar = do
  try (string "#\\")
  c <- anyChar 
  r <- many(letter)
  let chr = c:r
  return $ case chr of
    "space"   -> Char ' '
    "newline" -> Char '\n'
    _         -> Char c {- TODO: err if invalid char -}

parseOctalNumber :: Parser LispVal
parseOctalNumber = do
  try (string "#o")
  num <- many1(oneOf "01234567")
  return $ Number $ fst $ Numeric.readOct num !! 0

parseBinaryNumber :: Parser LispVal
parseBinaryNumber = do
  try (string "#b")
  num <- many1(oneOf "01")
  return $ Number $ fst $ Numeric.readInt 2 (`elem` "01") Char.digitToInt num !! 0

parseHexNumber :: Parser LispVal
parseHexNumber = do
  try (string "#x")
  sign <- many (oneOf "-")
  num <- many1(digit <|> oneOf "abcdefABCDEF")
  if (length sign) > 1
     then pzero
     else return $ Number $ fst $ Numeric.readHex num !! 0 -- TODO: apply sign, if one was read

{- Parser for Integer, base 10-}
parseDecimalNumber :: Parser LispVal
parseDecimalNumber = do
  try (many(string "#d"))
  sign <- many (oneOf "-")
  num <- many1 (digit)
  if (length sign) > 1
     then pzero
     else return $ (Number . read) $ sign ++ num

parseNumber :: Parser LispVal
parseNumber = parseDecimalNumber <|> 
              parseHexNumber     <|> 
              parseBinaryNumber  <|> 
              parseOctalNumber   <?> 
              "Unable to parse number"

{- Parser for floating points -}
parseDecimal :: Parser LispVal
parseDecimal = do 
  num <- many1(digit) -- TODO: support for negative numbers
  char '.'
  frac <- many1(digit)
  let dec = num ++ "." ++ frac
  return $ Float $ fst $ Numeric.readFloat dec !! 0

{- TODO: implement full numeric stack, see Parsing, exercise #7 -}


parseEscapedChar = do 
  char '\\'
  c <- anyChar
  return $ case c of
    'n' -> '\n'
    't' -> '\t'
    'r' -> '\r'
    _   -> c

parseString :: Parser LispVal
parseString = do
	char '"'
	x <- many (parseEscapedChar <|> noneOf("\""))
	char '"'
	return $ String x

parseVector :: Parser LispVal
parseVector = do
  vals <- sepBy parseExpr spaces
  return $ Vector (listArray (0, (length vals - 1)) vals)
-- TODO: old code from Data.Vector implementation:  return $ Vector $ Data.Vector.fromList vals

parseList :: Parser LispVal
parseList = liftM List $ sepBy parseExpr spaces

parseDottedList :: Parser LispVal
parseDottedList = do
  head <- endBy parseExpr spaces
  tail <- char '.' >> spaces >> parseExpr
  return $ DottedList head tail

parseQuoted :: Parser LispVal
parseQuoted = do
  char '\''
  x <- parseExpr
  return $ List [Atom "quote", x]

parseQuasiQuoted :: Parser LispVal
parseQuasiQuoted = do
  char '`'
  x <- parseExpr
  return $ List [Atom "quasiquote", x]

parseUnquoted :: Parser LispVal
parseUnquoted = do
  try (char ',')
  x <- parseExpr
  return $ List [Atom "unquote", x]

parseUnquoteSpliced :: Parser LispVal
parseUnquoteSpliced = do
  try (string ",@")
  x <- parseExpr
  return $ List [Atom "unquote-splicing", x]


-- Comment parser
-- TODO: this is a hack, it should really not return anything...
parseComment :: Parser LispVal
parseComment = do
  char ';'
  many (noneOf ("\n"))
  return $ Nil ""


parseExpr :: Parser LispVal
parseExpr = try(parseDecimal) 
  <|> parseComment
  <|> try(parseNumber)
  <|> parseChar
  <|> parseUnquoteSpliced
  <|> do try (string "#(")
         x <- parseVector
         char ')'
         return x
  <|> try (parseAtom)
  <|> parseString 
  <|> parseBool
  <|> parseQuoted
  <|> parseQuasiQuoted
  <|> parseUnquoted
  <|> do char '('
         x <- try parseList <|> parseDottedList
         char ')'
         return x
  <?> "Expression"

{- Macro eval section -}

-- Search for macro's in the AST, and transform any that are found.
-- There is also a special case (define-syntax) that loads new rules.
macroEval :: Env -> LispVal -> IOThrowsError LispVal
macroEval env (List [Atom "define-syntax", Atom keyword, syntaxRules@(List (Atom "syntax-rules" : (List identifiers : rules)))]) = do
  defineNamespacedVar env macroNamespace keyword syntaxRules
  return $ Nil "" -- Sentinal value

macroEval env lisp@(List (x@(List _) : xs)) = do
  first <- macroEval env x
  rest <- mapM (macroEval env) xs
  return $ List $ first : rest

-- TODO: equivalent matches/transforms for vectors
--       what about dotted lists?

macroEval env lisp@(List (Atom x : xs)) = do
  isDefined <- liftIO $ isNamespacedBound env macroNamespace x
  if isDefined
     then do
       syntaxRules@(List (Atom "syntax-rules" : (List identifiers : rules))) <- getNamespacedVar env macroNamespace x 
       -- Transform the input and then call macroEval again, since a macro may be contained within...
       macroEval env =<< macroTransform env (List identifiers) rules lisp
     else do
       rest <- mapM (macroEval env) xs
       return $ List $ (Atom x) : rest
macroEval _ lisp@(_) = return lisp

-- Given input and syntax-rules, determine if any rule is a match and transform it. 
-- TODO (later): validate that the pattern's template and pattern are consistent (IE: no vars in transform that do not appear in matching pattern - csi "stmt1" case)
--macroTransform :: Env -> [LispVal] -> LispVal -> LispVal -> IOThrowsError LispVal
macroTransform env identifiers rules@(rule@(List r) : rs) input = do
  localEnv <- liftIO $ nullEnv -- Local environment used just for this invocation
  result <- matchRule env identifiers localEnv rule input
  case result of 
    Nil _ -> macroTransform env identifiers rs input
    otherwise -> return result
macroTransform _ _ rules input = throwError $ BadSpecialForm "Input does not match a macro pattern" input

-- Determine if the next element matches 0-to-n times due to an ellipsis
macroElementMatchesMany :: LispVal -> Bool
macroElementMatchesMany (List (p:ps)) = do
  if length ps > 0
     then case (head ps) of
                Atom "..." -> True
                otherwise -> False
     else False
macroElementMatchesMany _ = False

--matchRule :: Env -> Env -> LispVal -> LispVal -> LispVal
matchRule env identifiers localEnv (List [p@(List patternVar), template@(List _)]) (List inputVar) = do
   let is = tail inputVar
   case p of 
      List (Atom _ : ps) -> do
        match <- loadLocal localEnv identifiers (List ps) (List is) False False
        case match of
           Bool False -> do
             return $ Nil "" --throwError $ BadSpecialForm "Input does not match macro pattern" (List is)
           otherwise -> do
		     transformRule localEnv 0 (List []) template (List [])
		     {- DEBUGGING: remove once macro's are working...
                      - trans <- transformRule localEnv 0 (List []) template (List [])
                     --flushStr $ show $ trans

                     temp <- getVar localEnv "vars"
                     temp2 <- getVar localEnv "vals"
                     throwError $ BadSpecialForm "DEBUG" $ List [temp, temp2]
                     throwError $ BadSpecialForm "DEBUG" trans-}
      otherwise -> throwError $ BadSpecialForm "Malformed rule in syntax-rules" p
        --
        -- loadLocal - determine if pattern matches input, loading input into pattern variables as we go,
        --             in preparation for macro transformation.
  where findAtom :: LispVal -> LispVal -> IOThrowsError LispVal
        findAtom (Atom target) (List (Atom a:as)) = do
          if target == a
             then return $ Bool True
             else findAtom (Atom target) (List as)
        findAtom target (List (badtype : _)) = throwError $ TypeMismatch "symbol" badtype -- TODO: test this, non-atoms should throw err
        findAtom target _ = return $ Bool False
  
        loadLocal :: Env -> LispVal -> LispVal -> LispVal -> Bool -> Bool -> IOThrowsError LispVal
        loadLocal localEnv identifiers pattern input hasEllipsis outerHasEllipsis = do -- TODO: kind of a hack to have both ellipsis vars. Is only outer req'd?
          case (pattern, input) of
               (List (p:ps), List (i:is)) -> do -- check first input against first pattern, recurse...

                 let hasEllipsis = macroElementMatchesMany pattern

                 -- TODO: error if ... detected when there is an outer ... ????
                 --       no, this should (eventually) be allowed. See scheme-faq-macros
			 
                 status <- checkLocal localEnv identifiers (hasEllipsis || outerHasEllipsis) p i 
                 case status of
                      -- No match
                      Bool False -> if hasEllipsis
                                        -- No match, must be finished with ...
                                        -- Move past it, but keep the same input.
                                        then loadLocal localEnv identifiers (List $ tail ps) (List (i:is)) False outerHasEllipsis
                                        else return $ Bool False
                      -- There was a match
                      otherwise -> if hasEllipsis
                                      then loadLocal localEnv identifiers pattern (List is) True outerHasEllipsis
                                      else loadLocal localEnv identifiers (List ps) (List is) False outerHasEllipsis

               -- Base case - All data processed
               (List [], List []) -> return $ Bool True

               -- Ran out of input to process
               (List (p:ps), List []) -> do
                                         let hasEllipsis = macroElementMatchesMany pattern
                                         if hasEllipsis && ((length ps) == 1) 
                                                   then return $ Bool True
                                                   else return $ Bool False

               -- Pattern ran out, but there is still input. No match.
               (List [], _) -> return $ Bool False

               -- Check input against pattern (both should be single var)
               (_, _) -> checkLocal localEnv identifiers (hasEllipsis || outerHasEllipsis) pattern input 

        -- Check pattern against input to determine if there is a match
        --
        --  @param localEnv - Local variables for the macro, used during transform
        --  @param hasEllipsis - Determine whether we are in a zero-or-many match.
        --                       Used for loading local vars and NOT for purposes of matching.
        --  @param pattern - Pattern to match
        --  @param input - Input to be matched
        checkLocal :: Env -> LispVal -> Bool -> LispVal -> LispVal -> IOThrowsError LispVal
        checkLocal localEnv identifiers hasEllipsis (Bool pattern) (Bool input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Number pattern) (Number input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Float pattern) (Float input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (String pattern) (String input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Char pattern) (Char input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Atom pattern) input = do
          if hasEllipsis
             -- Var is part of a 0-to-many match, store up in a list...
             then do isDefined <- liftIO $ isBound localEnv pattern
                     -- If pattern is a literal identifier, then just pass it along as-is
                     found <- findAtom (Atom pattern) identifiers
                     let val = case found of
                                 (Bool True) -> Atom pattern
                                 otherwise -> input
                     -- Set variable in the local environment
                     if isDefined
                        then do v <- getVar localEnv pattern
                                case v of
                                  (List vs) -> setVar localEnv pattern (List $ vs ++ [val])
                        else defineVar localEnv pattern (List [val])
             -- Simple var, load up into macro env
             else defineVar localEnv pattern input
          return $ Bool True

-- TODO, load into localEnv in some (all?) cases?: eqv [(Atom arg1), (Atom arg2)] = return $ Bool $ arg1 == arg2
-- TODO: eqv [(Vector arg1), (Vector arg2)] = eqv [List $ (elems arg1), List $ (elems arg2)] 
        checkLocal localEnv identifiers hasEllipsis (DottedList ps p) (DottedList is i) = 
          loadLocal localEnv identifiers (List $ ps ++ [p]) (List $ is ++ [i]) False hasEllipsis
        checkLocal localEnv identifiers hasEllipsis pattern@(List _) input@(List _) = 
          loadLocal localEnv identifiers pattern input False hasEllipsis

        checkLocal localEnv identifiers hasEllipsis _ _ = return $ Bool False

--
-- TODO: transforming into form (a b) ... does not work at the moment. Causes problems for (let*)
--
-- Transform input by walking the tranform structure and creating a new structure
-- with the same form, replacing identifiers in the tranform with those bound in localEnv
transformRule :: Env -> Int -> LispVal -> LispVal -> LispVal -> IOThrowsError LispVal

-- Recursively transform a list
transformRule localEnv ellipsisIndex (List result) transform@(List(List l : ts)) (List ellipsisList) = do
  let hasEllipsis = macroElementMatchesMany transform
  if hasEllipsis

--
-- LATEST - adding an ellipsisList which will temporarily hold the value of the "outer" result while we process the 
--          zero-or-more match. Once that is complete we will swap this value back into it's rightful place
--

     then do curT <- transformRule localEnv (ellipsisIndex + 1) (List []) (List l) (List result)
--             throwError $ BadSpecialForm "test" $ List [curT, Number $ toInteger ellipsisIndex, List l] -- TODO: debugging
             case curT of
                        -- TODO: this is the same code as below! Once it works, roll both into a common function
               Nil _ -> if ellipsisIndex == 0
                                -- First time through and no match ("zero" case)....
                           then transformRule localEnv 0 (List $ result) (List $ tail ts) (List []) -- tail => Move past the ...
                           else transformRule localEnv 0 (List $ ellipsisList ++ result) (List $ tail ts) (List [])
               List t -> if lastElementIsNil t
			                     -- Base case, there is no more data to transform for this ellipsis
                            -- 0 (and above nesting) means we cannot allow more than one ... active at a time (OK per spec???)
                            then if ellipsisIndex == 0
                                         -- First time through and no match ("zero" case)....
                                    then transformRule localEnv 0 (List $ result) (List $ tail ts) (List [])
                                    else transformRule localEnv 0 (List $ ellipsisList ++ result) (List $ tail ts) (List [])
			                     -- Next iteration of the zero-to-many match
                            else do if ellipsisIndex == 0
                                    -- First time through, swap out result
                                      then do 
                                              transformRule localEnv (ellipsisIndex + 1) (List [curT]) transform (List result)
                                    -- Keep going...
                                      else do 
                                              transformRule localEnv (ellipsisIndex + 1) (List $ result ++ [curT]) transform (List ellipsisList)

     else do lst <- transformRule localEnv ellipsisIndex (List []) (List l) (List ellipsisList)
             case lst of
                  List _ -> transformRule localEnv ellipsisIndex (List $ result ++ [lst]) (List ts) (List ellipsisList)
                  otherwise -> throwError $ BadSpecialForm "Macro transform error" $ List [lst, (List l), Number $ toInteger ellipsisIndex]

  where lastElementIsNil l = case (last l) of
                               Nil _ -> True
                               otherwise -> False
        getListAtTail l = case (last l) of
                               List lst -> lst

-- TODO: vector transform (and taking vectors into account in other cases as well???)
-- TODO: what about dotted lists?

-- Transform an atom by attempting to look it up as a var...
transformRule localEnv ellipsisIndex (List result) transform@(List (Atom a : ts)) unused = do
  let hasEllipsis = macroElementMatchesMany transform
  isDefined <- liftIO $ isBound localEnv a
  if hasEllipsis
     then if isDefined
             then do
                  -- get var
                  var <- getVar localEnv a
                  -- ensure it is a list
                  case var of 
                    -- add all elements of the list into result
                    List v -> transformRule localEnv ellipsisIndex (List $ result ++ v) (List $ tail ts) unused
                    v@(_) -> transformRule localEnv ellipsisIndex (List $ result ++ [v]) (List $ tail ts) unused
             else -- Matched 0 times, skip it
                  transformRule localEnv ellipsisIndex (List result) (List $ tail ts) unused
     else do t <- if isDefined
                     then do var <- getVar localEnv a
                             if ellipsisIndex > 0 
                                then do case var of
                                          List v -> if (length v) > (ellipsisIndex - 1)
                                                       then return $ v !! (ellipsisIndex - 1)
                                                       else return $ Nil ""
					            else return var
                     else if ellipsisIndex > 0
                             then return $ Nil "" -- Zero-match case
                             else return $ Atom a -- Not defined in the macro, just pass it through the macro as-is
             case t of
               Nil _ -> return t
               otherwise -> transformRule localEnv ellipsisIndex (List $ result ++ [t]) (List ts) unused

-- Transform anything else as itself...
transformRule localEnv ellipsisIndex result@(List r) transform@(List (t : ts)) unused = do
  transformRule localEnv ellipsisIndex (List $ r ++ [t]) (List ts) unused

-- Base case - empty transform
transformRule localEnv ellipsisIndex result@(List _) transform@(List []) unused = do
  return result

{- Eval section -}
eval :: Env -> LispVal -> IOThrowsError LispVal
eval env val@(Nil _) = return val
eval env val@(String _) = return val
eval env val@(Char _) = return val
eval env val@(Number _) = return val
eval env val@(Float _) = return val
eval env val@(Bool _) = return val
eval env (Atom id) = getVar env id
eval env (List [Atom "quote", val]) = return val
eval env (List [Atom "quasiquote", val]) = do
  case val of
    List [Atom "unquote", val] -> eval env val -- Handle cases like `,(+ 1 2) 
    List [Atom "unquote-splicing", val] -> eval env val -- TODO: not quite right behavior 
    List (x : xs) -> mapM (doUnQuote env) (x:xs) >>= return . List -- TODO: understand *why* this works 
    otherwise -> doUnQuote env val 
  where doUnQuote :: Env -> LispVal -> IOThrowsError LispVal
        doUnQuote env val = do
          case val of
            List [Atom "unquote", val] -> eval env val
            List [Atom "unquote-splicing", val] -> eval env val -- TODO: not quite right behavior
            otherwise -> eval env (List [Atom "quote", val]) -- TODO: could this be simplified?

eval env (List [Atom "if", pred, conseq, alt]) = {- TODO: alt should be optional (though not per spec)-} 
    do result <- eval env pred
       case result of
         Bool False -> eval env alt
         otherwise -> eval env conseq
         {- ex #1: only allow boolean conditions: otherwise -> throwError $ TypeMismatch "bool" otherwise-}

-- TODO: implement this 'if' form, such that it returns nothing if the pred evaluates to false
eval env (List [Atom "if", pred, conseq]) = 
    do result <- eval env pred
       case result of
         Bool True -> eval env conseq
         otherwise -> eval env $ List []

eval env (List (Atom "cond" : clauses)) = 
  if length clauses == 0
   then throwError $ BadSpecialForm "No matching clause" $ String "cond"
   else do
       let c =  clauses !! 0 -- First clause
       let cs = tail clauses -- other clauses
       test <- case c of
         List (Atom "else" : expr) -> eval env $ Bool True
         List (cond : expr) -> eval env cond
         badType -> throwError $ TypeMismatch "clause" badType 
       case test of
         Bool True -> evalCond env c
         otherwise -> eval env $ List $ (Atom "cond" : cs)

eval env (List (Atom "case" : keyAndClauses)) = 
    do let key = keyAndClauses !! 0
       let cls = tail keyAndClauses
       ekey <- eval env key
       evalCase env $ List $ (ekey : cls)

eval env (List (Atom "begin" : funcs)) = 
  if length funcs == 0
     then eval env $ Nil ""
     else if length funcs == 1
             then eval env (head funcs)
             else do
                 let fs = tail funcs
                 eval env (head funcs)
                 eval env (List (Atom "begin" : fs))

eval env (List [Atom "load", String filename]) =
     load filename >>= liftM last . mapM (evaluate env)
	 where evaluate env val = macroEval env val >>= eval env

eval env (List [Atom "set!", Atom var, form]) = 
  eval env form >>= setVar env var

eval env (List [Atom "define", Atom var, form]) = 
  eval env form >>= defineVar env var

eval env (List (Atom "define" : List (Atom var : params) : body )) = 
  makeNormalFunc env params body >>= defineVar env var
eval env (List (Atom "define" : DottedList (Atom var : params) varargs : body)) = 
  makeVarargs varargs env params body >>= defineVar env var
eval env (List (Atom "lambda" : List params : body)) = 
  makeNormalFunc env params body
eval env (List (Atom "lambda" : DottedList params varargs : body)) = 
  makeVarargs varargs env params body
eval env (List (Atom "lambda" : varargs@(Atom _) : body)) = 
  makeVarargs varargs env [] body

eval env (List [Atom "string-fill!", Atom var, character]) = do 
  str <- eval env =<< getVar env var
  chr <- eval env character
  (eval env $ fillStr(str, chr)) >>= setVar env var
  where fillStr (String str, Char chr) = doFillStr (String "", Char chr, length str)
  
        doFillStr (String str, Char chr, left) = do
        if left == 0
           then String str
           else doFillStr(String $ chr : str, Char chr, left - 1)

eval env (List [Atom "string-set!", Atom var, index, character]) = do 
  idx <- eval env index
  chr <- eval env character
  str <- eval env =<< getVar env var
  (eval env $ substr(str, character, idx)) >>= setVar env var
  where substr (String str, Char chr, Number index) = do
                              let slength = fromInteger index
                              String $ (take (fromInteger index) . drop 0) str ++ 
                                       [chr] ++
                                       (take (length str) . drop (fromInteger index + 1)) str
    -- TODO: error handler

eval env val@(Vector _) = return val

eval env (List [Atom "vector-set!", Atom var, index, object]) = do 
  idx <- eval env index
  obj <- eval env object
  vec <- eval env =<< getVar env var
  (eval env $ (updateVector vec idx obj)) >>= setVar env var
  where updateVector (Vector vec) (Number idx) obj = Vector $ vec//[(fromInteger idx, obj)]
        -- TODO: error handler?
-- TODO: error handler? - eval env (List [Atom "vector-set!", args]) = throwError $ NumArgs 2 args

eval env (List [Atom "vector-fill!", Atom var, object]) = do 
  obj <- eval env object
  vec <- eval env =<< getVar env var
  (eval env $ (fillVector vec obj)) >>= setVar env var
  where fillVector (Vector vec) obj = do
          let l = replicate (lenVector vec) obj
          Vector $ (listArray (0, length l - 1)) l
        lenVector v = length (elems v)
        -- TODO: error handler?
-- TODO: error handler? - eval env (List [Atom "vector-fill!", args]) = throwError $ NumArgs 2 args

eval env (List (function : args)) = do
  func <- eval env function
  argVals <- mapM (eval env) args
  apply func argVals

--Obsolete (?) - eval env (List (Atom func : args)) = mapM (eval env) args >>= liftThrows . apply func
eval env badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

-- Helper function for evaluating 'case'
-- TODO: still need to handle case where nothing matches key
--       (same problem exists with cond, if)
evalCase :: Env -> LispVal -> IOThrowsError LispVal
evalCase env (List (key : cases)) = do
         let c = cases !! 0
         ekey <- eval env key
         case c of
           List (Atom "else" : exprs) -> last $ map (eval env) exprs
           List (List cond : exprs) -> do test <- checkEq env ekey (List cond)
                                          case test of
                                            Bool True -> last $ map (eval env) exprs
                                            otherwise -> evalCase env $ List $ ekey : tail cases
           badForm -> throwError $ BadSpecialForm "Unrecognized special form in case" badForm
  where
    checkEq env ekey (List (x : xs)) = do 
     test <- eval env $ List [Atom "eqv?", ekey, x]
     case test of
       Bool True -> eval env $ Bool True
       otherwise -> checkEq env ekey (List xs)

    checkEq env ekey val =
     case val of
       List [] -> eval env $ Bool False -- If nothing else is left, then nothing matched key
       otherwise -> do
          test <- eval env $ List [Atom "eqv?", ekey, val]
          case test of
            Bool True -> eval env $ Bool True
            otherwise -> eval env $ Bool False

evalCase key badForm = throwError $ BadSpecialForm "case: Unrecognized special form" badForm

-- Helper function for evaluating 'cond'
evalCond :: Env -> LispVal -> IOThrowsError LispVal
evalCond env (List [test, expr]) = eval env expr
evalCond env (List (test : expr)) = last $ map (eval env) expr -- TODO: all expr's need to be evaluated, not sure happening right now
evalCond env badForm = throwError $ BadSpecialForm "evalCond: Unrecognized special form" badForm

makeFunc varargs env params body = return $ Func (map showVal params) varargs body env
makeNormalFunc = makeFunc Nothing
makeVarargs = makeFunc . Just . showVal

apply :: LispVal -> [LispVal] -> IOThrowsError LispVal
apply (IOFunc func) args = func args
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (Func params varargs body closure) args =
  if num params /= num args && varargs == Nothing
     then throwError $ NumArgs (num params) args
     else (liftIO $ bindVars closure $ zip (map ((,) varNamespace) params) args) >>= bindVarArgs varargs >>= evalBody
  where remainingArgs = drop (length params) args
        num = toInteger . length
        evalBody env = liftM last $ mapM (eval env) body
        bindVarArgs arg env = case arg of
          Just argName -> liftIO $ bindVars env [((varNamespace, argName), List $ remainingArgs)]
          Nothing -> return env
apply func args = throwError $ BadSpecialForm "Unable to evaluate form" $ List (func : args)

primitiveBindings :: IO Env
primitiveBindings = nullEnv >>= (flip bindVars $ map (makeFunc IOFunc) ioPrimitives
                                              ++ map (makeFunc PrimitiveFunc) primitives)
  where makeFunc constructor (var, func) = ((varNamespace, var), constructor func)

ioPrimitives :: [(String, [LispVal] -> IOThrowsError LispVal)]
ioPrimitives = [("apply", applyProc),
                ("open-input-file", makePort ReadMode),
                ("open-output-file", makePort WriteMode),
                ("close-input-port", closePort),
                ("close-output-port", closePort),
                ("read", readProc),
                ("write", writeProc),
                ("read-contents", readContents),
                ("read-all", readAll)]

applyProc :: [LispVal] -> IOThrowsError LispVal
applyProc [func, List args] = apply func args
applyProc (func : args) = apply func args

makePort :: IOMode -> [LispVal] -> IOThrowsError LispVal
makePort mode [String filename] = liftM Port $ liftIO $ openFile filename mode

closePort :: [LispVal] -> IOThrowsError LispVal
closePort [Port port] = liftIO $ hClose port >> (return $ Bool True)
closePort _ = return $ Bool False

readProc :: [LispVal] -> IOThrowsError LispVal
readProc [] = readProc [Port stdin]
readProc [Port port] = (liftIO $ hGetLine port) >>= liftThrows . readExpr

writeProc :: [LispVal] -> IOThrowsError LispVal
writeProc [obj] = writeProc [obj, Port stdout]
writeProc [obj, Port port] = liftIO $ hPrint port obj >> (return $ Nil "")

readContents :: [LispVal] -> IOThrowsError LispVal
readContents [String filename] = liftM String $ liftIO $ readFile filename

load :: String -> IOThrowsError [LispVal]
load filename = (liftIO $ readFile filename) >>= liftThrows . readExprList

readAll :: [LispVal] -> IOThrowsError LispVal
readAll [String filename] = liftM List $ load filename

primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
              ("-", numericBinop(-)),
              ("*", numericBinop(*)),
              ("/", numericBinop div),
              ("mod", numericBinop mod),
              ("quotient", numericBinop quot),
              ("remainder", numericBinop rem),

              ("=", numBoolBinop (==)),
              ("<", numBoolBinop (<)),
              (">", numBoolBinop (>)),
              ("/=", numBoolBinop (/=)),
              (">=", numBoolBinop (>=)),
              ("<=", numBoolBinop (<=)),
              ("&&", boolBoolBinop (&&)),
              ("||", boolBoolBinop (||)),
              ("string=?", strBoolBinop (==)),
              ("string<?", strBoolBinop (<)),
              ("string>?", strBoolBinop (>)),
              ("string<=?", strBoolBinop (<=)),
              ("string>=?", strBoolBinop (>=)),
              ("string-ci=?", stringCIEquals),
              ("string-ci<?", stringCIBoolBinop (<)),
              ("string-ci>?", stringCIBoolBinop (>)),
              ("string-ci<=?", stringCIBoolBinop (<=)),
              ("string-ci>=?", stringCIBoolBinop (>=)),

              ("car", car),
              ("cdr", cdr),
              ("cons", cons),
              ("eq?", eqv),
              ("eqv?", eqv),
              ("equal?", equal),

              ("pair?", isDottedList),
              ("procedure?", isProcedure),
{-
			  TODO: full numeric tower: number?, complex?, rational?
			  --}
              ("number?", isNumber),
              ("integer?", isInteger),
              ("real?", isReal),
              ("list?", unaryOp isList),
              ("null?", isNull),
              ("symbol?", isSymbol),
              ("symbol->string", symbol2String),
              ("string->symbol", string2Symbol),
              ("char?", isChar),

              ("vector?", unaryOp isVector),
              ("make-vector", makeVector),
              ("vector", buildVector),
              ("vector-length", vectorLength),
              ("vector-ref", vectorRef),
              ("vector->list", vectorToList),
              ("list->vector", listToVector),

              ("string?", isString),
              ("string", buildString),
              ("make-string", makeString),
              ("string-length", stringLength),
              ("string-ref", stringRef),
              ("substring", substring),
              ("string-append", stringAppend),
              ("string->number", stringToNumber),
              ("string->list", stringToList),
              ("list->string", listToString),
              ("string-copy", stringCopy),

              ("boolean?", isBoolean)]

data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

unpackEquals :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool
unpackEquals arg1 arg2 (AnyUnpacker unpacker) = 
  do unpacked1 <- unpacker arg1
     unpacked2 <- unpacker arg2
     return $ unpacked1 == unpacked2
  `catchError` (const $ return False)

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args = if length args /= 2
                             then throwError $ NumArgs 2 args
                             else do left <- unpacker $ args !! 0
                                     right <- unpacker $ args !! 1
                                     return $ Bool $ left `op` right

unaryOp :: (LispVal -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
unaryOp f [v] = f v

numBoolBinop = boolBinop unpackNum
strBoolBinop = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool s) = return $ show s
unpackStr notString = throwError $ TypeMismatch "string" notString

unpackBool :: LispVal -> ThrowsError Bool
unpackBool  (Bool b) = return b
unpackBool notBool = throwError $ TypeMismatch "boolean" notBool

numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> ThrowsError LispVal
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params = mapM unpackNum params >>= return . Number . foldl1 op

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
{- Obsolete code: unpackNum (String n) = let parsed = reads n in
                           if null parsed
                             then 0
                             else fst $ parsed !! 0
unpackNum (List [n]) = unpackNum n-}
unpackNum notNum = throwError $ TypeMismatch "number" notNum

{- List primitives -}
car :: [LispVal] -> ThrowsError LispVal
car [List (x : xs)] = return x
car [DottedList (x : xs) _] = return x
car [badArg] = throwError $ TypeMismatch "pair" badArg
car badArgList = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x : xs)] = return $ List xs
cdr [DottedList [xs] x] = return x
cdr [DottedList (_ : xs) x] = return $ DottedList xs x
cdr [badArg] = throwError $ TypeMismatch "pair" badArg
cdr badArgList = throwError $ NumArgs 1 badArgList

cons :: [LispVal] -> ThrowsError LispVal
cons [x1, List []] = return $ List [x1]
cons [x, List xs] = return $ List $ x : xs
cons [x, DottedList xs xlast] = return $ DottedList (x : xs) xlast
cons [x1, x2] = return $ DottedList [x1] x2
cons badArgList = throwError $ NumArgs 2 badArgList

eqv :: [LispVal] -> ThrowsError LispVal
eqv [(Bool arg1), (Bool arg2)] = return $ Bool $ arg1 == arg2
eqv [(Number arg1), (Number arg2)] = return $ Bool $ arg1 == arg2
eqv [(Float arg1), (Float arg2)] = return $ Bool $ arg1 == arg2
eqv [(String arg1), (String arg2)] = return $ Bool $ arg1 == arg2
eqv [(Char arg1), (Char arg2)] = return $ Bool $ arg1 == arg2
eqv [(Atom arg1), (Atom arg2)] = return $ Bool $ arg1 == arg2
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [(Vector arg1), (Vector arg2)] = eqv [List $ (elems arg1), List $ (elems arg2)] 
eqv [l1@(List arg1), l2@(List arg2)] = eqvList eqv [l1, l2]
eqv [_, _] = return $ Bool False
eqv badArgList = throwError $ NumArgs 2 badArgList

eqvList :: ([LispVal] -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
eqvList eqvFunc [(List arg1), (List arg2)] = return $ Bool $ (length arg1 == length arg2) && 
                                                    (all eqvPair $ zip arg1 arg2)
    where eqvPair (x1, x2) = case eqvFunc [x1, x2] of
                               Left err -> False
                               Right (Bool val) -> val

equal :: [LispVal] -> ThrowsError LispVal
equal [(Vector arg1), (Vector arg2)] = eqvList equal [List $ (elems arg1), List $ (elems arg2)] 
equal [l1@(List arg1), l2@(List arg2)] = eqvList equal [l1, l2]
equal [(DottedList xs x), (DottedList ys y)] = equal [List $ xs ++ [x], List $ ys ++ [y]]
equal [arg1, arg2] = do
  primitiveEquals <- liftM or $ mapM (unpackEquals arg1 arg2)
                     [AnyUnpacker unpackNum, AnyUnpacker unpackStr, AnyUnpacker unpackBool]
  eqvEquals <- eqv [arg1, arg2]
  return $ Bool $ (primitiveEquals || let (Bool x) = eqvEquals in x)
equal badArgList = throwError $ NumArgs 2 badArgList

-------------- Vector Primitives --------------

makeVector, buildVector, vectorLength, vectorRef, vectorToList, listToVector :: [LispVal] -> ThrowsError LispVal
makeVector [(Number n)] = makeVector [Number n, List []]
makeVector [(Number n), a] = do
  let l = replicate (fromInteger n) a 
  return $ Vector $ (listArray (0, length l - 1)) l
makeVector [badType] = throwError $ TypeMismatch "integer" badType 
makeVector badArgList = throwError $ NumArgs 1 badArgList

buildVector (o:os) = do
  let lst = o:os
  return $ Vector $ (listArray (0, length lst - 1)) lst
buildVector badArgList = throwError $ NumArgs 1 badArgList

vectorLength [(Vector v)] = return $ Number $ toInteger $ length (elems v)
vectorLength [badType] = throwError $ TypeMismatch "vector" badType 
vectorLength badArgList = throwError $ NumArgs 1 badArgList

vectorRef [(Vector v), (Number n)] = return $ v ! (fromInteger n)
vectorRef [badType] = throwError $ TypeMismatch "vector integer" badType 
vectorRef badArgList = throwError $ NumArgs 2 badArgList

vectorToList [(Vector v)] = return $ List $ elems v 
vectorToList [badType] = throwError $ TypeMismatch "vector" badType 
vectorToList badArgList = throwError $ NumArgs 1 badArgList

listToVector [(List l)] = return $ Vector $ (listArray (0, length l - 1)) l
listToVector [badType] = throwError $ TypeMismatch "list" badType 
listToVector badArgList = throwError $ NumArgs 1 badArgList
-------------- String Primitives --------------

buildString :: [LispVal] -> ThrowsError LispVal
buildString [(Char c)] = return $ String [c]
buildString (Char c:rest) = do
  cs <- buildString rest
  case cs of
    String s -> return $ String $ [c] ++ s
    badType -> throwError $ TypeMismatch "character" badType
buildString [badType] = throwError $ TypeMismatch "character" badType
buildString badArgList = throwError $ NumArgs 1 badArgList

makeString :: [LispVal] -> ThrowsError LispVal
makeString [(Number n)] = return $ doMakeString n ' ' ""
makeString [(Number n), (Char c)] = return $ doMakeString n c ""
makeString badArgList = throwError $ NumArgs 1 badArgList

doMakeString n chr s = 
    if n == 0 
       then String s
       else doMakeString (n - 1) chr (s ++ [chr])

stringLength :: [LispVal] -> ThrowsError LispVal
stringLength [String s] = return $ Number $ foldr (const (+1)) 0 s -- Could probably do 'length s' instead...
stringLength [badType] = throwError $ TypeMismatch "string" badType
stringLength badArgList = throwError $ NumArgs 1 badArgList

stringRef :: [LispVal] -> ThrowsError LispVal
stringRef [(String s), (Number k)] = return $ Char $ s !! fromInteger k
stringRef [badType] = throwError $ TypeMismatch "string number" badType
stringRef badArgList = throwError $ NumArgs 2 badArgList

substring :: [LispVal] -> ThrowsError LispVal
substring [(String s), (Number start), (Number end)] = 
  do let length = fromInteger $ end - start
     let begin = fromInteger start 
     return $ String $ (take length . drop begin) s
substring [badType] = throwError $ TypeMismatch "string number number" badType
substring badArgList = throwError $ NumArgs 3 badArgList

stringCIEquals :: [LispVal] -> ThrowsError LispVal
stringCIEquals [(String s1), (String s2)] = do
  if (length s1) /= (length s2)
     then return $ Bool False
     else return $ Bool $ ciCmp s1 s2 0
  where ciCmp s1 s2 idx = if idx == (length s1)
                             then True
                             else if (toLower $ s1 !! idx) == (toLower $ s2 !! idx)
                                     then ciCmp s1 s2 (idx + 1)
                                     else False
stringCIEquals [badType] = throwError $ TypeMismatch "string string" badType
stringCIEquals badArgList = throwError $ NumArgs 2 badArgList

stringCIBoolBinop :: ([Char] -> [Char] -> Bool) -> [LispVal] -> ThrowsError LispVal
stringCIBoolBinop op [(String s1), (String s2)] = boolBinop unpackStr op [(String $ strToLower s1), (String $ strToLower s2)]
  where strToLower str = map (toLower) str 
stringCIBoolBinop op [badType] = throwError $ TypeMismatch "string string" badType
stringCIBoolBinop op badArgList = throwError $ NumArgs 2 badArgList

stringAppend :: [LispVal] -> ThrowsError LispVal
stringAppend [(String s)] = return $ String s -- Needed for "last" string value
stringAppend (String st:sts) = do
  rest <- stringAppend sts
-- TODO: I needed to use <- instead of "let = " here, for type problems. Why???
-- TBD: this probably will solve type problems when processing other lists of objects in the other string functions
  case rest of
    String s -> return $ String $ st ++ s
    otherwise -> throwError $ TypeMismatch "string" otherwise
stringAppend [badType] = throwError $ TypeMismatch "string" badType
stringAppend badArgList = throwError $ NumArgs 1 badArgList

-- This could be expanded, for now just converts integers
stringToNumber :: [LispVal] -> ThrowsError LispVal
stringToNumber [(String s)] = return $ Number $ read s
stringToNumber [badType] = throwError $ TypeMismatch "string" badType
stringToNumber badArgList = throwError $ NumArgs 1 badArgList

stringToList :: [LispVal] -> ThrowsError LispVal
stringToList [(String s)] = return $ List $ map (Char) s
stringToList [badType] = throwError $ TypeMismatch "string" badType
stringToList badArgList = throwError $ NumArgs 1 badArgList

listToString :: [LispVal] -> ThrowsError LispVal
listToString [(List [])] = return $ String ""
listToString [(List l)] = buildString l
listToString [badType] = throwError $ TypeMismatch "list" badType

stringCopy :: [LispVal] -> ThrowsError LispVal
stringCopy [String s] = return $ String s
stringCopy [badType] = throwError $ TypeMismatch "string" badType
stringCopy badArgList = throwError $ NumArgs 2 badArgList

isNumber :: [LispVal] -> ThrowsError LispVal
isNumber ([Number n]) = return $ Bool True
isNumber ([Float f]) = return $ Bool True
isNumber _ = return $ Bool False

isReal :: [LispVal] -> ThrowsError LispVal
isReal ([Number n]) = return $ Bool True
isReal ([Float f]) = return $ Bool True
isReal _ = return $ Bool False

isInteger :: [LispVal] -> ThrowsError LispVal
isInteger ([Number n]) = return $ Bool True
isInteger _ = return $ Bool False

isDottedList :: [LispVal] -> ThrowsError LispVal
isDottedList ([DottedList l d]) = return $ Bool True
isDottedList _ = return $  Bool False

isProcedure :: [LispVal] -> ThrowsError LispVal
isProcedure ([PrimitiveFunc f]) = return $ Bool True
isProcedure ([Func params vararg body closure]) = return $ Bool True
isProcedure ([IOFunc f]) = return $ Bool True
isProcedure _ = return $ Bool False

isVector, isList :: LispVal -> ThrowsError LispVal
isVector (Vector _) = return $ Bool True
isVector _          = return $ Bool False
isList (List _) = return $ Bool True
isList _        = return $ Bool False

isNull :: [LispVal] -> ThrowsError LispVal
isNull ([List []]) = return $ Bool True
isNull _ = return $ Bool False

isSymbol :: [LispVal] -> ThrowsError LispVal
isSymbol ([Atom a]) = return $ Bool True
isSymbol _ = return $ Bool False

symbol2String :: [LispVal] -> ThrowsError LispVal
symbol2String ([Atom a]) = return $ String a
symbol2String [notAtom] = throwError $ TypeMismatch "symbol" notAtom

string2Symbol :: [LispVal] -> ThrowsError LispVal
string2Symbol ([String s]) = return $ Atom s
string2Symbol [notString] = throwError $ TypeMismatch "string" notString

isChar :: [LispVal] -> ThrowsError LispVal
isChar ([Char a]) = return $ Bool True
isChar _ = return $ Bool False

isString :: [LispVal] -> ThrowsError LispVal
isString ([String s]) = return $ Bool True
isString _ = return $ Bool False

isBoolean :: [LispVal] -> ThrowsError LispVal
isBoolean ([Bool n]) = return $ Bool True
isBoolean _ = return $ Bool False
{- end Eval section-}


