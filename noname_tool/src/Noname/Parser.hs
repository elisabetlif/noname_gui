-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Noname.Parser
Description : Parser for specification of security protocols.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Parser (parseSpecification) where

-- base
import Control.Monad (when)
import Data.Foldable (for_, traverse_)
import Data.List (delete, elemIndex, find, sort)

-- containers
import Data.Map ((!))
import qualified Data.Map as Map

-- megaparsec
import Text.Megaparsec hiding (State)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as Lexer

-- parser-combinators
import Control.Monad.Combinators.Expr

-- text
import Data.Text (Text)
import qualified Data.Text as Text

-- transformers
import Control.Monad.Trans.State (StateT, get, modify, put, runStateT)

-- noname
import Noname.Pretty
import Noname.State

-- | The datatype for custom parse errors.
data CustomError
  = -- | Unexpected keyword.
    Keyword Identifier
  | -- | Identifier used without declaration.
    NotDeclared Identifier
  | -- | Identifier not fresh, i.e., already declared.
    NotFresh Identifier Symbol
  | -- | Identifier used in a way that does not match its declaration.
    Usage Identifier Text Symbol
  | -- | Rewrite rule violating requirements of supported algebras.
    RewriteRule Text
  | -- | Context not ground, i.e., containing variables (other than @'hole'@).
    NotGround Context
  | -- | Destructor application that is neither unary nor binary.
    DestructorArity
  | -- | Transaction name already declared.
    TransactionName Identifier
  deriving (Eq, Ord)

-- | The instance so that custom errors can be used with @'Parsec'@.
instance ShowErrorComponent CustomError where
  showErrorComponent (Keyword x) = Text.unpack $ mconcat [x, " used as identifier but is a reserved keyword."]
  showErrorComponent (NotDeclared x) = Text.unpack $ mconcat [x, " must be declared before use."]
  showErrorComponent (NotFresh x s) =
    Text.unpack $
      mconcat [x, " must be fresh but declared as ", prettySymbol s, "."]
  showErrorComponent (Usage x txt s) =
    Text.unpack $
      mconcat [x, " used as ", txt, " but declared as ", prettySymbol s, "."]
  showErrorComponent (RewriteRule txt) = Text.unpack txt
  showErrorComponent (NotGround t) = Text.unpack $ mconcat [prettyMessage t, " must be ground."]
  showErrorComponent DestructorArity = "Destructors must be either unary or binary."
  showErrorComponent (TransactionName name) = Text.unpack $ mconcat [name, " is already declared as a transaction."]

-- | Type synonym for the stateful parser.
type Parser = StateT State (Parsec CustomError Text)

-- | Skip whitespace and comment lines.
spaceConsumer :: Parser ()
spaceConsumer = Lexer.space space1 (Lexer.skipLineComment "#") empty

-- | Apply the given parser and then consume whitespace and comments.
lexeme :: Parser a -> Parser a
lexeme = Lexer.lexeme spaceConsumer

-- | Parse the given text and consume any following whitespace and comments.
symbol :: Text -> Parser Text
symbol = Lexer.symbol spaceConsumer

-- | Parse an integer.
int :: Parser Int
int = lexeme Lexer.decimal

-- | Parser the given keyword.
keyword :: Text -> Parser ()
keyword k = lexeme $ string k *> notFollowedBy alphaNumChar

-- | The list of keywords.
keys :: [Text]
keys =
  [ "Sigma0"
  , "Sigma"
  , "public"
  , "private"
  , "relation"
  , "gamma0"
  , "Algebra"
  , "Cells"
  , "Transaction"
  , "receive"
  , "let"
  , "try"
  , "in"
  , "catch"
  , "if"
  , "then"
  , "else"
  , "new"
  , "send"
  , "nil"
  , "or"
  , "and"
  , "not"
  , "true"
  , "Bound"
  ]

-- | Parse an identifier and verifies that it is not a keyword.
identifier :: Parser Identifier
identifier = lexeme . label "identifier" $ do
  x <- Text.pack <$> ((:) <$> letterChar <*> many alphaNumChar)
  if x `elem` keys
    then customFailure $ Keyword x
    else pure x

-- | Parse a fresh identifier.
freshId :: Parser Identifier
freshId = label "fresh identifier" $ do
  x <- identifier
  st <- symbolTab <$> get
  case Map.lookup x st of
    Nothing -> pure x
    Just s -> customFailure $ NotFresh x s

-- | Parse a function declaration.
funArity :: Parser Function
funArity = try $ do
  f <- freshId <* symbol "/"
  n <- int
  modify $ \state -> state{symbolTab = Map.insert f (Fun n) $ symbolTab state}
  pure f

-- | Parse a relation declaration.
relArity :: Parser ()
relArity = try $ do
  r <- freshId <* symbol "/"
  n <- int
  modify $ \state -> state{symbolTab = Map.insert r (Rel n) $ symbolTab state}

-- | Add the function to the list of public functions.
mkPublic :: Function -> Parser ()
mkPublic f = modify $ \state -> state{public = f : public state}

-- | Parse the declaration of \(\Sigma_0\).
sigma0 :: Parser ()
sigma0 = do
  keyword "Sigma0" <* symbol ":"
  mfs <- optional $ keyword "public" *> some funArity -- FIXME should we only have constants?
  _ <- optional $ keyword "private" *> some funArity -- FIXME should we remove private functions?
  _ <- optional $ keyword "relation" *> some relArity
  for_ mfs $ traverse_ mkPublic

-- | Parse the declaration of \(\Sigma\).
sigma :: Parser ()
sigma = do
  keyword "Sigma" <* symbol ":"
  mfs <- optional $ keyword "public" *> some funArity
  _ <- optional $ keyword "private" *> some funArity
  for_ mfs $ traverse_ mkPublic

-- | Parse a message.
message :: Parser Message
message = label "message" $ do
  x <- identifier
  mts <- optional $ symbol "(" *> message `sepBy` symbol "," <* symbol ")"
  st <- symbolTab <$> get
  case (Map.lookup x st, mts) of
    (Nothing, _) -> customFailure $ NotDeclared x
    (Just (Pvar _), Nothing) -> pure $ Atom x
    (Just Ivar, Nothing) -> pure $ Atom x
    (Just (Fun 0), Nothing) -> pure $ Comp x []
    (Just (Fun n), Just ts) -> do
      let n' = length ts
      if n == n'
        then pure $ Comp x ts
        else customFailure . Usage x (prettySymbol $ Fun n') $ Fun n
    (Just s, Nothing) -> customFailure $ Usage x "variable or constant" s
    (Just s, Just ts) -> customFailure $ Usage x (prettySymbol . Fun $ length ts) s

-- | Parse an interpretation of a relation.
pInterpretation :: Parser (Relation, [[Message]])
pInterpretation = try $ do
  r <- identifier <* symbol ":"
  tss <-
    (symbol "(" *> message `sepBy` symbol "," <* symbol ")") `sepBy1` symbol ","
  st <- symbolTab <$> get
  case Map.lookup r st of
    Nothing -> customFailure $ NotDeclared r
    Just (Rel n) ->
      case find ((/= n) . length) tss of
        Nothing -> pure (r, tss)
        Just ts -> customFailure . Usage r (prettySymbol . Rel $ length ts) $ Rel n
    Just s -> customFailure $ Usage r "relation" s

-- | Parse the fixed interpretation \(\gamma_0\) of all relations.
pGamma0 :: Parser ()
pGamma0 = do
  keyword "gamma0" <* symbol ":"
  traverse_ (\(r, tss) -> modify $ interpret r tss) =<< some pInterpretation
 where
  interpret :: Relation -> [[Message]] -> State -> State
  interpret r tss state =
    state{interpretation = Map.insertWith (++) r tss $ interpretation state}

-- | Parse a fresh message, i.e., all variables in the message must be fresh.
freshMessage :: Parser Message
freshMessage = label "fresh message" $ do
  x <- identifier
  mts <- optional $ symbol "(" *> freshMessage `sepBy` symbol "," <* symbol ")"
  st <- symbolTab <$> get
  case (Map.lookup x st, mts) of
    (Nothing, Nothing) -> pure $ Atom x
    (Nothing, Just _) -> customFailure $ NotDeclared x
    (Just (Fun 0), Nothing) -> pure $ Comp x []
    (Just (Fun n), Just ts) -> do
      let n' = length ts
      if n == n'
        then pure $ Comp x ts
        else customFailure . Usage x (prettySymbol $ Fun n') $ Fun n
    (Just s, Nothing) -> customFailure $ NotFresh x s
    (Just s, Just ts) -> customFailure $ Usage x (prettySymbol . Fun $ length ts) s

-- | Check (some) requirements of supported algebras.
mkRewriteRule
  :: Function
  -> Maybe (Message, Message)
  -> Function
  -> [Message]
  -> Message
  -> Parser ()
mkRewriteRule df mks f ts t = do
  state <- get
  when (Map.member df $ theory state) . customFailure . RewriteRule $
    mconcat ["The destructor ", df, " must occur in at most one rewrite rule."]
  let prettyTs = Text.intercalate "," $ map prettyMessage ts
  when (isPublic state df && sort ts /= sort (map Atom $ concatMap vars ts))
    . customFailure
    . RewriteRule
    $ mconcat
      [ "The arguments "
      , prettyTs
      , " of the constructor "
      , f
      , " must be fresh and distinct variables."
      ]
  when (isPublic state df && t `notElem` ts) . customFailure . RewriteRule $
    mconcat
      [ "The result "
      , prettyMessage t
      , " must be one of the variables in "
      , prettyTs
      , "."
      ]
  when (not $ isPublic state df || any (isSubterm t) ts)
    . customFailure
    . RewriteRule
    $ mconcat
      [ "The result "
      , prettyMessage t
      , " must be a subterm of one the messages "
      , prettyTs
      , "."
      ]
  case mks of
    Nothing -> addRewriteRule [Comp f ts]
    Just (k, k') -> do
      when (sort (vars k) /= sort (vars k')) . customFailure . RewriteRule $
        mconcat
          [ "The keys "
          , prettyMessage k
          , " and "
          , prettyMessage k'
          , " must have the same variables."
          ]
      addRewriteRule [k, Comp f $ k' : ts]
 where
  addRewriteRule :: [Message] -> Parser ()
  addRewriteRule ts' = do
    modify $ \state -> state{theory = Map.insert df (ts', t) $ theory state}
    modify $ \state -> state{destructorTab = Map.insertWith (++) f [df] $ destructorTab state}

  isSubterm :: Message -> Message -> Bool
  isSubterm t1 t2 =
    case t2 of
      Atom _ -> t1 == t2
      Comp _ t2s -> any (isSubterm t1) t2s

-- | Parse a rewrite rule.
rewriteRule :: Parser ()
rewriteRule = try $ do
  df <- identifier <* symbol "("
  (f, mks) <- try withKeys <|> withoutKeys
  ts <- freshMessage `sepBy` symbol "," <* symbol ")" <* symbol ")"
  t <- symbol "->" *> freshMessage
  mkRewriteRule df mks f ts t
 where
  withKeys :: Parser (Function, Maybe (Message, Message))
  withKeys = do
    k <- freshMessage <* symbol ","
    f <- identifier <* symbol "("
    k' <- freshMessage <* symbol ","
    pure (f, Just (k, k'))

  withoutKeys :: Parser (Function, Maybe (Message, Message))
  withoutKeys = do
    f <- identifier <* symbol "("
    pure (f, Nothing)

-- | Parse the definition of the algebra, i.e., the set of rewrite rules.
algebra :: Parser ()
algebra = do
  keyword "Algebra" <* symbol ":"
  () <$ some rewriteRule

{- | Parse a cell declaration, i.e., a cell name with its initial ground
context.
-}
cellDeclaration :: Parser ()
cellDeclaration = try $ do
  cell <- freshId
  x <- symbol "[" *> freshId <* symbol "]"
  t <- substitute (Map.singleton x $ Atom hole) <$> (symbol ":=" *> freshMessage)
  when (any (/= hole) $ vars t) . customFailure $ NotGround t
  modify $ \state -> state{symbolTab = Map.insert cell Cel $ symbolTab state}
  modify $ \state -> state{contextTab = Map.insert cell t $ contextTab state}

-- | Parse the definition of the cells, i.e., all cell declarations.
cells :: Parser ()
cells = do
  keyword "Cells" <* symbol ":"
  () <$ some cellDeclaration

-- | Parse a transaction declaration.
transaction :: Parser ()
transaction = do
  keyword "Transaction"
  name <- identifier <* symbol ":"
  state <- get
  case Map.lookup name $ transactionTab state of
    Nothing -> do
      pl <- leftProcess
      put state{transactionTab = Map.insert name pl $ transactionTab state}
    Just _ -> customFailure $ TransactionName name

-- | Parse a left process.
leftProcess :: Parser LeftProcess
leftProcess =
  choice
    [ try $ symbol "{" *> leftProcess <* symbol "}"
    , choicePvar
    , receive
    , letLeft
    , Center <$> centerProcess
    ]

-- | Parse a non-deterministic choice of privacy variable.
choicePvar :: Parser LeftProcess
choicePvar = do
  mode <- (Star <$ symbol "*") <|> (Diamond <$ symbol "<>")
  x <- freshId
  _ <- symbol "in"
  d <- symbol "{" *> constant `sepBy1` symbol "," <* symbol "}"
  modify $ \state -> state{symbolTab = Map.insert x (Pvar d) $ symbolTab state}
  Choice mode x d
    <$> ((symbol "." *> leftProcess) <|> (pure . Center $ New [] Nil))
 where
  constant :: Parser Function
  constant = do
    c <- identifier
    _ <- optional $ symbol "(" *> symbol ")"
    st <- symbolTab <$> get
    case Map.lookup c st of
      Nothing -> customFailure $ NotDeclared c
      Just (Fun 0) -> pure c
      Just s -> customFailure $ Usage c (prettySymbol $ Fun 0) s

-- | Parse a message received.
receive :: Parser LeftProcess
receive = do
  keyword "receive"
  x <- freshId
  modify $ \state -> state{symbolTab = Map.insert x Ivar $ symbolTab state}
  Receive x
    <$> ((symbol "." *> leftProcess) <|> (pure . Center $ New [] Nil))

-- | Parse a let expression in a left process.
letLeft :: Parser LeftProcess
letLeft = do
  keyword "let"
  x <- freshId
  _ <- symbol "="
  t <- message
  modify $ \state -> state{symbolTab = Map.insert x Ivar $ symbolTab state}
  LetLeft x t
    <$> ((symbol "." *> leftProcess) <|> (pure . Center $ New [] Nil))

-- | Parse a center process.
centerProcess :: Parser CenterProcess
centerProcess =
  choice
    [ try $ symbol "{" *> centerProcess <* symbol "}"
    , tryCatch
    , conditional
    , letCenter
    , new
    , cellRead
    , New [] <$> rightProcess
    ]

-- | Parse a destructor application.
tryCatch :: Parser CenterProcess
tryCatch = do
  keyword "try"
  x <- freshId <* symbol ":="
  df <- identifier
  ts <- symbol "(" *> message `sepBy` symbol "," <* symbol ")"
  let n = length ts
  when (n >= 3) $ customFailure DestructorArity
  state <- get
  case Map.lookup df $ symbolTab state of
    Nothing -> customFailure $ NotDeclared df
    Just (Fun n') ->
      when (n /= n') . customFailure . Usage df (prettySymbol $ Fun n) $ Fun n'
    Just s -> customFailure $ Usage df (prettySymbol $ Fun n) s
  put state{symbolTab = Map.insert x Ivar $ symbolTab state}
  _ <- symbol "in"
  pc <- centerProcess
  Try x df ts pc
    <$> ((symbol "catch" *> put state *> centerProcess) <|> pure (New [] Nil))

-- | Parse a conditional statement.
conditional :: Parser CenterProcess
conditional = do
  state <- get
  If
    <$> (keyword "if" *> formula)
    <*> (keyword "then" *> centerProcess)
    <*> ((keyword "else" *> put state *> centerProcess) <|> pure (New [] Nil))

-- | Parse a cell name.
cellName :: Parser Cell
cellName = do
  cell <- identifier
  st <- symbolTab <$> get
  case Map.lookup cell st of
    Nothing -> customFailure $ NotDeclared cell
    Just Cel -> pure cell
    Just s -> customFailure $ Usage cell (prettySymbol Cel) s

-- | Parse a cell read.
cellRead :: Parser CenterProcess
cellRead = try $ do
  x <- freshId <* symbol ":="
  modify $ \state -> state{symbolTab = Map.insert x Ivar $ symbolTab state}
  Read x
    <$> cellName
    <*> (symbol "[" *> message <* symbol "]")
    <*> ((symbol "." *> centerProcess) <|> pure (New [] Nil))

-- | Parse a let expression in a center process.
letCenter :: Parser CenterProcess
letCenter = do
  keyword "let"
  x <- freshId
  _ <- symbol "="
  t <- message
  modify $ \state -> state{symbolTab = Map.insert x Ivar $ symbolTab state}
  LetCenter x t <$> ((symbol "." *> centerProcess) <|> pure (New [] Nil))

-- | Parse generation of fresh constants.
new :: Parser CenterProcess
new = do
  keyword "new"
  xs <- freshId `sepBy1` symbol ","
  let st = Map.fromList $ map (,Ivar) xs
  modify $ \state -> state{symbolTab = Map.union st $ symbolTab state}
  New xs <$> ((symbol "." *> rightProcess) <|> pure Nil)

-- | Parse a right process.
rightProcess :: Parser RightProcess
rightProcess =
  choice
    [ try $ symbol "{" *> rightProcess <* symbol "}"
    , send
    , release
    , letRight
    , cellWrite
    , Nil <$ keyword "nil"
    ]

-- | Parse a message sent.
send :: Parser RightProcess
send =
  Send
    <$> (keyword "send" *> message)
    <*> ((symbol "." *> rightProcess) <|> pure Nil)

-- | Parse a formula released.
release :: Parser RightProcess
release =
  Release
    <$> (Star <$ symbol "*")
    <*> formula
    <*> ((symbol "." *> rightProcess) <|> pure Nil)

-- | Parse a cell write.
cellWrite :: Parser RightProcess
cellWrite =
  try $
    Write
      <$> cellName
      <*> (symbol "[" *> message <* symbol "]")
      <*> (symbol ":=" *> message)
      <*> ((symbol "." *> rightProcess) <|> pure Nil)

-- | Parse a let expression in a right process.
letRight :: Parser RightProcess
letRight = do
  keyword "let"
  x <- freshId
  _ <- symbol "="
  t <- message
  modify $ \state -> state{symbolTab = Map.insert x Ivar $ symbolTab state}
  LetRight x t <$> ((symbol "." *> rightProcess) <|> pure Nil)

-- | Parse a formula.
formula :: Parser Formula
formula = makeExprParser termFormula operatorTable

-- | Parse a formula term.
termFormula :: Parser Formula
termFormula =
  choice
    [ symbol "(" *> formula <* symbol ")"
    , relational
    , equality
    , membership
    , Top <$ keyword "true"
    ]

-- | Parse a relational formula.
relational :: Parser Formula
relational = try $ do
  r <- identifier
  ts <- symbol "(" *> message `sepBy` symbol "," <* symbol ")"
  let n = length ts
  st <- symbolTab <$> get
  case Map.lookup r st of
    Nothing -> customFailure $ NotDeclared r
    Just (Rel n') ->
      if n == n'
        then pure $ Relational r ts
        else customFailure . Usage r (prettySymbol $ Rel n) $ Rel n'
    Just s -> customFailure $ Usage r (prettySymbol $ Rel n) s

-- | Parse an equality formula.
equality :: Parser Formula
equality = try $ Equality <$> message <*> (symbol "=" *> message)

-- | Parse a membership formula.
membership :: Parser Formula
membership = try $ do
  t <- message
  keyword "in"
  ts <- symbol "{" *> message `sepBy1` symbol "," <* symbol "}"
  pure . disjunction $ map (Equality t) ts

-- | Operator table for the precedence and fixity of operators on formulas.
operatorTable :: [[Operator Parser Formula]]
operatorTable =
  [ [Prefix (Neg <$ keyword "not")]
  , [InfixL ((\phi psi -> conjunction [phi, psi]) <$ keyword "and")]
  , [InfixL ((\phi psi -> disjunction [phi, psi]) <$ keyword "or")]
  ]

-- | Add the standard cryptographic primitives to the state.
addStandardOps :: State -> State
addStandardOps state =
  let stdFuns =
        [ ("crypt", Fun 3)
        , ("dcrypt", Fun 2)
        , ("scrypt", Fun 3)
        , ("dscrypt", Fun 2)
        , ("sign", Fun 2)
        , ("open", Fun 2)
        , ("inv", Fun 1)
        , ("pubk", Fun 1)
        , ("pk", Fun 1)
        , ("pair", Fun 2)
        , ("proj1", Fun 1)
        , ("proj2", Fun 1)
        ]
      stdTheory =
        Map.fromList
          [
            ( "dcrypt"
            , ([Comp "inv" [Atom "X"], Comp "crypt" [Atom "X", Atom "Y", Atom "Z"]], Atom "Y")
            )
          ,
            ( "dscrypt"
            , ([Atom "X", Comp "scrypt" [Atom "X", Atom "Y", Atom "Z"]], Atom "Y")
            )
          ,
            ( "open"
            , ([Atom "X", Comp "sign" [Comp "inv" [Atom "X"], Atom "Y"]], Atom "Y")
            )
          , ("pubk", ([Comp "inv" [Atom "X"]], Atom "X"))
          , ("proj1", ([Comp "pair" [Atom "X", Atom "Y"]], Atom "X"))
          , ("proj2", ([Comp "pair" [Atom "X", Atom "Y"]], Atom "Y"))
          ]
      stdDestructorTab =
        Map.fromList
          [ ("crypt", ["dcrypt"])
          , ("scrypt", ["dscrypt"])
          , ("sign", ["open"])
          , ("inv", ["pubk"])
          , ("pair", ["proj1", "proj2"])
          ]
      stdPublic = delete "inv" $ map fst stdFuns
  in  state
        { symbolTab = Map.union (Map.fromList stdFuns) $ symbolTab state
        , theory = Map.union stdTheory $ theory state
        , destructorTab = Map.unionWith (++) stdDestructorTab $ destructorTab state
        , public = stdPublic ++ public state
        }

{- | Whether, in the given state, the function must be transparent, i.e., there
are \(n\) public destructors, each giving the \(i\)th subterm for \(i \in \{1,
\dots, n\}\), where \(n\) is the arity of the function.
-}
mustBeTransparent :: State -> Function -> Bool
mustBeTransparent state f =
  let dfs = filter (isPublic state) <$> Map.lookup f (destructorTab state)
      mns = traverse (projectedIndex . (theory state !)) =<< dfs
  in  case sort <$> mns of
        Nothing -> False
        Just ns -> ns == [1 .. arity state f]
 where
  projectedIndex :: ([Message], Message) -> Maybe Int
  projectedIndex ([Comp _ ts], t) = (+ 1) <$> elemIndex t ts
  -- projectedIndex ([_, Comp _ (_ : ts)], t) = (+ 1) <$> elemIndex t ts
  projectedIndex _ = Nothing

{- | Add all functions that must be transparent to the list of transparent
functions in the state.
-}
addTransparent :: State -> State
addTransparent state =
  let fs = filter (mustBeTransparent state) . Map.keys $ destructorTab state
  in  state{transparent = fs ++ transparent state}

-- | Parse the bound on the number of transitions.
bound :: Parser Int
bound = (keyword "Bound" *> symbol ":" *> int) <|> pure 0

{- | Parse a protocol specification: the state is updated during parsing and
the value returned is the bound on the number of transitions.
-}
specification :: Parser Int
specification = do
  modify $ \state -> state{symbolTab = Map.insert meta (Fun 1) $ symbolTab state}
  modify $ \state -> state{symbolTab = Map.insert hole Ivar $ symbolTab state}
  modify addStandardOps
  spaceConsumer
  _ <- optional sigma0
  _ <- optional sigma
  _ <- optional pGamma0
  _ <- optional algebra
  _ <- optional cells
  _ <- optional $ some transaction
  modify addTransparent
  bound <* eof

{- | Parse the specification from the given input. Return either parse
errors or the bound on the number of transitions and the updated state.
-}
parseSpecification :: FilePath -> Text -> Either Text (Int, State)
parseSpecification fp input =
  case runParser (runStateT specification initialState) fp input of
    Left e -> Left . Text.pack $ errorBundlePretty e
    Right ns -> Right ns
