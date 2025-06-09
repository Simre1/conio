# ConIO

Haskell has great tools for dealing with concurrency. However, in praxis they are difficult to use.

This library aims to make concurrency easy by providing many built-in solutions for common concurrency patterns.
It implements [structured concurrency](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful), not letting threads outlive their parent scope. Additionally, exceptions are propagated automatically. This means that you do not have to worry about:

- Zombie processes, since a thread can never outlive its parent scope.
- Dead processes, since exceptions will propagate to the parent thread.


## Examples

```haskell
example1 :: IO ()
example1 =
  -- open up a concurrency scope
  runConIO $ do
    -- launch tasks
    task1 <- launch action1
    task2 <- launch action2
    pure ()
  -- waits until `action1` and `action2` are done
```

```haskell
example2 :: IO ()
example2 =
  -- open up a concurrency scope
  runConIO $ do
    -- launch task
    task <- launch $ pure 10
    
    -- do some work
    let x = 10

    -- wait for task to complete and get the result
    result <- wait task

    -- prints 20
    print $ x + result
```

```haskell
example3 :: IO ()
example3 =
  -- open up a concurrency scope
  runConIO $ do
    -- launch task
    task <- launch $ threadDelay 10000000

    -- cancel task
    cancel task
```


```haskell
example4 :: IO ()
example4 =
  -- open up a concurrency scope
  runConIO $ do
    -- launch task
    task <- raceTwo (threadDelay 1000000 >> pure 10) (pure 20)

    -- wait for result and cancel the slower thread
    result <- wait task

    -- prints 20
    print result
```


## Comparison with other libraries

- `ki`: Implements structured concurrency, but has has no high-level functions
- `async`: Does not implement structured concurrency

## Acknowledgements

- Inspired by [Notes on structured concurrency](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful), which is implemented in the `trio` Python library.
