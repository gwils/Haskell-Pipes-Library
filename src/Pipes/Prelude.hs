{-| General purpose utilities

    The names in this module clash heavily with the Haskell Prelude, so I
    recommend that you import this module qualified:

> import qualified Pipes.Prelude as P

    Note that the really important functions (like 'for' and 'each') reside in
    the "Pipes" module.  This module primarily houses utilities that are not as
    central in importance but are still nice to have.
-}

{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

module Pipes.Prelude (
    -- * Producers
    -- $producers
    stdin,
    fromHandle,

    -- * Unfolds
    -- $unfolds
    replicate,
    replicateM,
    yieldIf,
    read,

    -- * Push-based Pipes
    -- $push
    take,
    takeWhile,
    drop,
    dropWhile,
    findIndices,
    scanl,
    scanM,

    -- * Folds
    foldl,
    foldM,
    all,
    any,
    find,
    findIndex,
    head,
    index,
    last,
    null,

    -- * Zips
    zip,
    zipWith,

    -- * Utilities
    tee,
    generalize
    ) where

import Control.Monad (liftM, replicateM_, when, unless)
import Control.Monad.Trans.State.Strict (get, put)
import qualified System.IO   as IO
import Pipes
import Pipes.Lift (evalStateP)
import Prelude hiding (
    all,
    any,
    drop,
    dropWhile,
    foldl,
    read,
    head,
    last,
    null,
    replicate,
    scanl,
    take,
    takeWhile,
    zip,
    zipWith )

{- $producers
    Use 'for' to iterate over 'Producer's whenever you want to perform the same
    action for every element:

> -- Echo all lines from standard input to standard output
> runEffect $
>     for P.stdin $ \str -> do
>         lift $ putStrLn str
>
> -- or more concisely:
> runEffect $ for P.stdin (lift . putStrLn)

    Note that 'String'-based 'IO' is inefficient.  These 'Producer's exist only
    for simple demonstrations without incurring a dependency on the @text@
    package.

    Also, don't forget about 'each', exported by the main "Pipes" module.  Or
    you can build your own custom 'Producer's using 'yield' and the 'Monad'
    instance for 'Producer's.
-}

-- | Read 'String's from 'IO.stdin' using 'getLine'
stdin :: Producer' String IO ()
stdin = fromHandle IO.stdin
{-# INLINABLE stdin #-}

-- | Read 'String's from a 'IO.Handle' using 'IO.hGetLine'
fromHandle :: IO.Handle -> Producer' String IO ()
fromHandle h = go
  where
    go = do
        eof <- lift $ IO.hIsEOF h
        unless eof $ do
            str <- lift $ IO.hGetLine h
            yield str
            go
{-# INLINABLE fromHandle #-}

{- $unfolds
    You also use 'for' to apply an unfold to a stream, generating a new
    'Producer' like this:

> -- Duplicate every input string
> for P.stdin (P.replicate 2) :: Producer String IO ()

    To apply an additional handler, you can either iterate over the newly minted
    'Producer' using another 'for' loop:

> runEffect $
>     for (for P.stdin (P.replicate 2)) $ \str -> do
>         lift $ putStrLn str

    ... or you can nest 'for' loops:

> runEffect $
>     for P.stdin $ \str1 -> do
>         for (P.replicate 2 str1) $ \str2 -> do
>             lift $ putStrLn str2

    ... or you can compose the two handlers using ('/>/'):

> main3 = runEffect $ for P.stdin (P.replicate 2 />/ lift . putStrLn)
-}

-- | @(replicate n a)@ 'yield's the value \'@a@\' a total of \'@n@\' times.
replicate :: (Monad m) => Int -> a -> Producer' a m ()
replicate n a = replicateM_ n (yield a)
{-# INLINABLE replicate #-}

{-| @(replicateM n m)@ calls \'@m@\' a total of \'@n@\' times, 'yield'ing each
    result.
-}
replicateM :: (Monad m) => Int -> m a -> Producer' a m ()
replicateM n m = replicateM_ n $ do
    a <- lift m
    yield a
{-# INLINABLE replicateM #-}

-- | @(yieldIf pred a)@ only re-'yield's @a@ if it satisfies the predicate @p@
yieldIf :: (Monad m) => (a -> Bool) -> a -> Producer' a m ()
yieldIf predicate a = if (predicate a) then yield a else return ()
{-# INLINABLE yieldIf #-}

-- | Parse 'Read'able values, only forwarding the value if the parse succeeds
read :: (Monad m, Read a) => String -> Producer' a m ()
read str = case (reads str) of
    [(a, "")] -> yield a
    _         -> return ()
{-# INLINABLE read #-}

{- $push
    Use ('~>') to transform a 'Producer' using a push-based 'Pipe':

>>> runEffect $ for (P.stdin ~> P.takeWhile (/= "quit")) (lift . putStrLn)
Test<Enter>
Test
ABC<Enter>
ABC
quit<Enter>
>>>

    You do not need to provide the last argument for these 'Pipe's (i.e. the
    \"@a@\").  That extra argument is what makes these push-based 'Pipe's and
    this is how ('~>') feeds in their first input.
-}

-- | @(take n)@ only allows @n@ values to pass through
take :: (Monad m) => Int -> a -> Pipe a a m ()
take = go
  where
    go n a =
        if (n <= 0)
        then return ()
        else do
            yield a
            await () >>= go (n - 1)
{-# INLINABLE take #-}

{-| @(takeWhile p)@ allows values to pass downstream so long as they satisfy
    the predicate @p@.
-}
takeWhile :: (Monad m) => (a -> Bool) -> a -> Pipe a a m ()
takeWhile predicate = go
  where
    go a =
        if (predicate a)
        then do
            yield a
            await () >>= go
        else return ()
{-# INLINABLE takeWhile #-}

-- | @(drop n)@ discards @n@ values going downstream
drop :: (Monad m) => Int -> a -> Pipe a a m r
drop = go
  where
    go n a =
        if (n <= 0)
        then push a
        else do
            yield a
            await () >>= go (n - 1)
{-# INLINABLE drop #-}

{-| @(dropWhile p)@ discards values going downstream until one violates the
    predicate @p@.
-}
dropWhile :: (Monad m) => (a -> Bool) -> a -> Pipe a a m r
dropWhile predicate = go
  where
    go a =
        if (predicate a)
        then await () >>= go
        else push a
{-# INLINABLE dropWhile #-}

-- | Outputs the indices of all elements that satisfied the predicate
findIndices :: (Monad m) => (a -> Bool) -> a -> Pipe a Int m r
findIndices predicate = loop 0
  where
    loop n a = do
        when (predicate a) (yield n)
        await () >>= (loop $! n + 1)
{-# INLINABLE findIndices #-}

-- | Strict left scan
scanl :: (Monad m) => (b -> a -> b) -> b -> a -> Pipe a b m r
scanl step b0 a0 = loop a0 b0
  where
    loop a b = do
        yield b
        a' <- await ()
        let b' = step b a
        loop a' $! b'
{-# INLINABLE scanl #-}

-- | Strict, monadic left scan
scanM :: (Monad m) => (b -> a -> m b) -> b -> a -> Pipe a b m r
scanM step b0 a0 = loop a0 b0
  where
    loop a b = do
        yield b
        a' <- await ()
        b' <- lift (step b a)
        loop a' $! b'
{-# INLINABLE scanM #-}

-- | Strict fold of the elements of a 'Producer'
foldl :: (Monad m) => (b -> a -> b) -> b -> Producer a m r -> m b
foldl step b0 p0 = loop p0 b0
  where
    loop p b = do
        x <- next p
        case x of
            Left   _      -> return b
            Right (a, p') -> loop p' $! step b a
{-# INLINABLE foldl #-}

-- | Strict, monadic fold of the elements of a 'Producer'
foldM :: (Monad m) => (b -> a -> m b) -> b -> Producer a m r -> m b
foldM step b0 p0 = loop p0 b0
  where
    loop p b = do
        x <- next p
        case x of
            Left   _      -> return b
            Right (a, p') -> do
                b' <- step b a
                loop p' $! b'
{-# INLINABLE foldM #-}

{-| @(all predicate p)@ determines whether all the elements of @p@ satisfy the
    predicate.

    'all' stops drawing elements if any element fails the predicate
-}
all :: (Monad m) => (a -> Bool) -> Producer a m r -> m Bool
all predicate p = null $ for p (yieldIf (not . predicate))
{-# INLINABLE all #-}

{-| @(any predicate p)@ determines whether any element of @p@ satisfies the
    predicate.

    'any' stops drawing elements if any element satisfies the predicate
-}
any :: (Monad m) => (a -> Bool) -> Producer a m r -> m Bool
any predicate p = liftM not $ null $ for p (yieldIf predicate)
{-# INLINABLE any #-}

-- | Find the first value that satisfies the predicate
find :: (Monad m) => (a -> Bool) -> Producer a m r -> m (Maybe a)
find predicate p = head $ for p (yieldIf predicate)
{-# INLINABLE find #-}

-- | Find the index of the first value that satisfies the predicate
findIndex :: (Monad m) => (a -> Bool) -> Producer a m r -> m (Maybe Int)
findIndex predicate p = head (p ~> findIndices predicate)
{-# INLINABLE findIndex #-}

-- | Retrieve the first value from a 'Producer'
head :: (Monad m) => Producer a m r -> m (Maybe a)
head p = do
    x <- next p
    case x of
        Left   _     -> return Nothing
        Right (a, _) -> return (Just a)
{-# INLINABLE head #-}

-- | Index into a 'Producer'
index :: (Monad m) => Int -> Producer a m r -> m (Maybe a)
index n p = head (p ~> drop n)
{-# INLINABLE index #-}

-- | Retrieve the last value from a 'Producer'
last :: (Monad m) => Producer a m r -> m (Maybe a)
last p0 = do
    x <- next p0
    case x of
        Left   _      -> return Nothing
        Right (a, p') -> loop a p'
  where
    loop a p = do
        x <- next p
        case x of
            Left   _       -> return (Just a)
            Right (a', p') -> loop a' p'
{-# INLINABLE last #-}

-- | Determine if a 'Producer' is empty
null :: (Monad m) => Producer a m r -> m Bool
null p = do
    x <- next p
    return $ case x of
        Left  _ -> True
        Right _ -> False
{-# INLINABLE null #-}

-- | Zip two 'Producer's
zip :: (Monad m)
    => (Producer   a     m r)
    -> (Producer      b  m r)
    -> (Producer' (a, b) m r)
zip = zipWith (,)
{-# INLINABLE zip #-}

-- | Zip two 'Producer's using the provided combining function
zipWith :: (Monad m)
    => (a -> b -> c)
    -> (Producer  a m r)
    -> (Producer  b m r)
    -> (Producer' c m r)
zipWith f = go
  where
    go p1 p2 = do
        e1 <- lift $ next p1
        case e1 of
            Left r         -> return r
            Right (a, p1') -> do
                e2 <- lift $ next p2
                case e2 of
                    Left r         -> return r
                    Right (b, p2') -> do
                        yield (f a b)
                        go p1' p2'
{-# INLINABLE zipWith #-}

{-| Transform a 'Consumer' to a 'Pipe' that reforwards all values further
    downstream
-}
tee :: (Monad m) => (() -> Consumer a m r) -> (() -> Pipe a a m r)
tee p () = evalStateP Nothing $ do
    r <- (up \>\ (hoist lift . p />/ dn)) ()
    ma <- lift get
    case ma of
        Nothing -> return ()
        Just a  -> yield a
    return r
  where
    up () = do
        ma <- lift get
        case ma of
            Nothing -> return ()
            Just a  -> yield a
        a <- await ()
        lift $ put (Just a)
        return a
    dn _ = return ()
{-# INLINABLE tee #-}

{-| Transform a unidirectional 'Pipe' to a bidirectional 'Pipe'

> generalize (f >-> g) = generalize f >-> generalize g
>
> generalize pull = pull
-}
generalize :: (Monad m) => (() -> Pipe a b m r) -> x -> Proxy x a x b m r
generalize p x0 = evalStateP x0 $ (up \>\ hoist lift . p />/ dn) ()
  where
    up () = do
        x <- lift get
        await x
    dn a = do
        x <- yield a
        lift $ put x
{-# INLINABLE generalize #-}
