-- | Utility functions for arrays.

import "math"
import "soacs"
import "functional"
open import "zip" -- Rexport.

-- | The size of the outer dimension of an array.
let length [n] 't (_: [n]t) = n

-- | Is the array empty?
let null [n] 't (_: [n]t) = n == 0

-- | The first element of the array.
let head [n] 't (x: [n]t) = x[0]

-- | The last element of the array.
let last [n] 't (x: [n]t) = x[n-1]

-- | Everything but the first element of the array.
let tail [n] 't (x: [n]t) = x[1:]

-- | Everything but the last element of the array.
let init [n] 't (x: [n]t) = x[0:n-1]

-- | Take some number of elements from the head of the array.
let take [n] 't (i: i32) (x: [n]t): [i]t = x[0:i]

-- | Remove some number of elements from the head of the array.
let drop [n] 't (i: i32) (x: [n]t) = x[i:]

-- | Split an array at a given position.
let split [n] 't (i: i32) (xs: [n]t): ([i]t, []t) =
  (xs[:i] :> [i]t, xs[i:])

-- | Return the elements of the array in reverse order.
let reverse [n] 't (x: [n]t): [n]t = x[::-1] :> [n]t

-- | Concatenate two arrays.  Warning: never try to perform a reduction
-- with this operator; it will not work.
let (++) [n] [m] 't (xs: [n]t) (ys: [m]t): *[]t = intrinsics.concat (xs, ys)

-- | An old-fashioned way of saying `++`.
let concat [n] [m] 't (xs: [n]t) (ys: [m]t): *[]t = xs ++ ys

-- | Concatenation where the result has a predetermined size.  If the
-- provided size is wrong, the function will fail with a run-time
-- error.
let concat_to [n] [m] 't (k: i32) (xs: [n]t) (ys: [m]t): *[k]t = xs ++ ys :> [k]t

-- | Rotate an array some number of elements to the left.  A negative
-- rotation amount is also supported.
--
-- For example, if `b==rotate r a`, then `b[x+r] = a[x]`.
let rotate [n] 't (r: i32) (xs: [n]t): [n]t = intrinsics.rotate (r, xs) :> [n]t

-- | Construct an array of consecutive integers of the given length,
-- starting at 0.
let iota (n: i32): *[n]i32 =
  i32.iota n :> [n]i32

-- | Construct an array comprising valid indexes into some other
-- array, starting at 0.
let indices [n] 't (_: [n]t) : *[n]i32 =
  iota n

-- | Construct an array of the given length containing the given
-- value.
let replicate 't (n: i32) (x: t): *[n]t =
  i32.replicate n x :> [n]t

-- | Copy a value.  The result will not alias anything.
let copy 't (a: t): *t =
  ([a])[0]

-- | Combines the outer two dimensions of an array.
let flatten [n][m] 't (xs: [n][m]t): []t =
  intrinsics.flatten xs

-- | Like `flatten`@term, but where the final size is known.  Fails at
-- runtime if the provided size is wrong.
let flatten_to [n][m] 't (l: i32) (xs: [n][m]t): [l]t =
  flatten xs :> [l]t

-- | Combines the outer three dimensions of an array.
let flatten_3d [n][m][l] 't (xs: [n][m][l]t): []t =
  flatten (flatten xs)

-- | Combines the outer four dimensions of an array.
let flatten_4d [n][m][l][k] 't (xs: [n][m][l][k]t): []t =
  flatten (flatten_3d xs)

-- | Splits the outer dimension of an array in two.
let unflatten [p] 't (n: i32) (m: i32) (xs: [p]t): [n][m]t =
  intrinsics.unflatten (n, m, xs) :> [n][m]t

-- | Splits the outer dimension of an array in three.
let unflatten_3d [p] 't (n: i32) (m: i32) (l: i32) (xs: [p]t): [n][m][l]t =
  unflatten n m (unflatten (n*m) l xs)

-- | Splits the outer dimension of an array in four.
let unflatten_4d [p] 't (n: i32) (m: i32) (l: i32) (k: i32) (xs: [p]t): [n][m][l][k]t =
  unflatten n m (unflatten_3d (n*m) l k xs)

let transpose [n] [m] 't (a: [n][m]t): [m][n]t =
  intrinsics.transpose a :> [m][n]t

-- | True if all of the input elements are true.  Produces true on an
-- empty array.
let and [n] (xs: [n]bool) = all id xs

-- | True if any of the input elements are true.  Produces false on an
-- empty array.
let or [n] (xs: [n]bool) = any id xs

-- | Perform a *sequential* left-fold of an array.
let foldl [n] 'a 'b (f: a -> b -> a) (acc: a) (bs: [n]b): a =
  loop acc for b in bs do f acc b

-- | Perform a *sequential* right-fold of an array.
let foldr [n] 'a 'b (f: b -> a -> a) (acc: a) (bs: [n]b): a =
  foldl (flip f) acc (reverse bs)

-- | Create a value for each point in a one-dimensional index space.
let tabulate 'a (n: i32) (f: i32 -> a): *[n]a =
  map1 f (iota n)

-- | Create a value for each point in a two-dimensional index space.
let tabulate_2d 'a (n: i32) (m: i32) (f: i32 -> i32 -> a): *[n][m]a =
  map1 (f >-> tabulate m) (iota n)

-- | Create a value for each point in a three-dimensional index space.
let tabulate_3d 'a (n: i32) (m: i32) (o: i32) (f: i32 -> i32 -> i32 -> a): *[n][m][o]a =
  map1 (f >-> tabulate_2d m o) (iota n)
