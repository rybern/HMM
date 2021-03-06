{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
module AI.Function where

import Control.Monad (forM_)
import Control.Monad.Primitive
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as GM
import qualified Data.Vector.Unboxed as U
import qualified Data.Matrix.Unboxed as MU
import Debug.Trace
import Statistics.Sample

sumM :: (PrimMonad m, GM.MVector v Double) => v (PrimState m) Double -> m Double
sumM xs = loop xs 0 0
  where
    loop v !acc !i
        | i < n = do x <- GM.unsafeRead xs i
                     loop v (acc+x) (i+1)
        | otherwise = return acc
    n = GM.length xs
{-# INLINE sumM #-}

logSumExp :: G.Vector v Double => v Double -> Double
logSumExp xs = m + log (G.foldl' (\acc x -> acc + exp (x-m)) 0 xs)
  where
    m = G.maximum xs
{-# INLINE logSumExp #-}

logSumExpM :: (PrimMonad m, GM.MVector v Double) => v (PrimState m) Double -> m Double
logSumExpM xs = do
    m <- U.foldM' (\acc i -> return . max acc =<< GM.unsafeRead xs i) (-1/0) . U.enumFromN 0 $ n
    let f acc i = do
            x <- GM.unsafeRead xs i
            return $ acc + exp (x-m)
    s <- U.foldM' f 0 . U.enumFromN 0 $ n
    return $! m + log s
  where
    n = GM.length xs
{-# INLINE logSumExpM #-}

covWeighted :: U.Vector Double -> (U.Vector Double, Double) -> (U.Vector Double, Double) -> Double
covWeighted ws (xs, mx) (ys, my) = g . G.foldl' f (0,0) $ U.enumFromN 0 $ G.length ws
  where
    f (!a,!b) i = let w = ws G.! i
                      x = xs G.! i
                      y = ys G.! i
                  in (a + w * (x - mx) * (y - my), b+w)
    g (a,b) | a == 0 || b == 0 = traceShow ("zero covariance", a, b) 1e-200
            | otherwise = a / b
{-# INLINE covWeighted #-}

weightedMeanCovMatrix :: G.Vector v Double => U.Vector Double -> MU.Matrix Double -> (v Double, v Double)
weightedMeanCovMatrix ws xs | G.length ws /= MU.rows xs = error $ (show $ MU.rows xs) ++ "/" ++ (show $ G.length ws)
                            | otherwise = (means, covMat)
  where
    means = G.generate n $ \i -> meanWeighted $ G.zip (xs `MU.takeColumn` i) ws
    covMat = G.create $ do
        mat <- GM.new (n*n)
        forM_ [0..n-1] $ \i ->
            forM_ [i..n-1] $ \j -> do
                let cov = covWeighted ws (xs `MU.takeColumn` i, means G.! i) (xs `MU.takeColumn` j, means G.! j) 
                GM.unsafeWrite mat (i*n+j) cov
                GM.unsafeWrite mat (j*n+i) cov
        return mat
    n = MU.cols xs
{-# INLINE weightedMeanCovMatrix #-}

-- | return the weighted mean and the diagonal of covariance matrix
weightedMeanDiagCov :: G.Vector v Double => U.Vector Double -> MU.Matrix Double -> (v Double, v Double)
weightedMeanDiagCov ws xs | G.length ws /= MU.rows xs = error $ (show $ MU.rows xs) ++ "/" ++ (show $ G.length ws)
                             | otherwise = (means, diag)
  where
    means = G.generate n $ \i -> meanWeighted $ G.zip (xs `MU.takeColumn` i) ws
    diag = G.generate n $ \i -> let x = xs `MU.takeColumn` i
                                    m = means G.! i
                                in covWeighted ws (x,m) (x,m)
    n = MU.cols xs
{-# INLINE weightedMeanDiagCov #-}
