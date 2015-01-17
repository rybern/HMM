{-# LANGUAGE BangPatterns #-}

module AI.GaussianHMM.Algorithms where

import Control.Monad.Primitive 
import Control.Monad (forM_, foldM)
import Control.Monad.ST (runST)
import Numeric.LinearAlgebra.HMatrix (Matrix, Vector, (<>), invlndet, (!), tr, asRow, vector, matrix, reshape)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as GM
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import qualified Data.Matrix.Unboxed as MU
import qualified Data.Matrix.Generic as M
import qualified Data.Matrix.Generic.Mutable as MM
import qualified Data.Matrix.Storable as S
import Algorithms.GLasso (glasso)
import Statistics.Sample (mean)
import Data.List (groupBy, sortBy)
import Data.Ord
import Data.Function
import System.Random.MWC

import AI.Function
import AI.GaussianHMM.Types
import AI.Clustering.KMeans

import Debug.Trace

baumWelch :: Observation -> GaussianHMM -> (GaussianHMM, U.Vector Double)
baumWelch ob h = (GaussianHMM ini' trans' em', scales)
  where
    ini' = G.zipWith (\x y -> x + y - G.head scales) (fw `M.takeColumn` 0) (bw `M.takeColumn` 0)

    trans' = MM.create $ do
        mat <- MM.new (n,n)
        forM_ [0..n-1] $ \i ->
            forM_ [0..n-1] $ \j -> do
                let a_ij = a h (i,j)
                temp <- UM.new m
                forM_ [1 .. m - 1] $ \t -> do
                    let o = ob `M.takeRow` t
                        b_jo = b h j o
                        α_it' = fw `M.unsafeIndex` (i,t-1)
                        β_jt = bw `M.unsafeIndex` (j,t)
                    GM.unsafeWrite temp t $ b_jo + α_it' + β_jt
                x <- logSumExpM temp
                MM.unsafeWrite mat (i,j) $ a_ij + x
        normalizeRow mat
        return mat

    em' = G.generate n $ \i -> let ws = G.map f $ G.enumFromN 0 m
                                   f t = let α_it = fw `M.unsafeIndex` (i,t)
                                             β_it = bw `M.unsafeIndex` (i,t)
                                             sc = scales `G.unsafeIndex` t
                                          in exp $ α_it + β_it - sc
                                   (mean, cov) = weightedMeanCovMatrix ws ob
                               in mvn mean (convert cov) -- $ fst $ glasso cov 0.1)

    (fw, scales) = forward h ob
    bw = backward h ob scales
    n = nSt h
    m = M.rows ob

{-
-- | the E step in EM algorithm
eStep :: GaussianHMM -> Observation -> (
eStep h ob = 
  where
    (fw, sc) = forward h ob
    bw = backward h ob sc
    γ = G.zipWith (-) (G.zipWith (+) fw bw) sc
    ξ = 
-}

forward :: GaussianHMM -> Observation -> (MU.Matrix Double, U.Vector Double)
forward h ob = runST $ do
    mat <- MM.new (r,c)
    scales <- GM.new c

    -- update first column
    temp0 <- UM.new r
    forM_ [0..r-1] $ \i -> do
        let x = π h i + b h i (M.takeRow ob 0)
        GM.unsafeWrite temp0 i x
    s0 <- fmap negate . logSumExpM $ temp0
    GM.unsafeWrite scales 0 s0
    -- normalize
    forM_ [0..r-1] $ \i -> GM.unsafeRead temp0 i >>= MM.unsafeWrite mat (i,0) . (+s0)

    -- update the rest of columns
    forM_ [1..c-1] $ \t -> do
        temp <- UM.new r
        forM_ [0..r-1] $ \j -> do
            temp' <- UM.new r
            forM_ [0..r-1] $ \i -> do
                α_it' <- MM.read mat (i,t-1)
                GM.unsafeWrite temp' i $ α_it' + a h (i,j)
                
            sum_α_a <- logSumExpM temp'

            GM.unsafeWrite temp j $ sum_α_a + b h j (ob `M.takeRow` t)
            if isNaN (sum_α_a + b h j (ob `M.takeRow` t))
               then do
                   error $ show (sum_α_a, b h j (ob `M.takeRow` t))
               else return ()

        s <- fmap negate . logSumExpM $ temp
        GM.unsafeWrite scales t s
        -- normalize
        forM_ [0..r-1] $ \i -> GM.unsafeRead temp i >>= MM.unsafeWrite mat (i,t) . (+s)
    
    mat' <- MM.unsafeFreeze mat
    scales' <- G.unsafeFreeze scales
    return (mat', scales')
  where
    r = nSt h
    c = M.rows ob
{-# INLINE forward #-}

-- | backward in log scale
backward :: GaussianHMM -> Observation -> U.Vector Double -> MU.Matrix Double
backward h ob scales = MM.create $ do
    mat <- MM.new (r,c)
    -- fill in last column
    forM_ [0..r-1] $ \i -> MM.unsafeWrite mat (i,c-1) $ G.last scales
    
    forM_ [c-2,c-3..0] $ \t -> do
        let sc = scales `G.unsafeIndex` t
        forM_ [0..r-1] $ \i -> do
            temp <- UM.new r
            forM_ [0..r-1] $ \j -> do
                let b_jo = b h j $ ob `M.takeRow` (t+1)
                    a_ij = a h (i,j)
                β_jt' <- MM.unsafeRead mat (j,t+1)
                UM.unsafeWrite temp j $! b_jo + a_ij + β_jt'
            x <- logSumExpM temp
            MM.unsafeWrite mat (i,t) $! x + sc
    return mat
  where
    r = nSt h
    c = M.rows ob
{-# INLINE backward #-}

{-
randomInitial :: PrimMonad m
              => Gen (PrimState m)
              -> Observation
              -> Int
              -> m GaussianHMM
randomInitial g ob k = do
    vec <- uniformVector g $ n * k
  where
    n = M.rows ob
    -}

-- | construct inital HMM model by kmeans clustering
kMeansInitial :: PrimMonad m
              => Gen (PrimState m)
              -> Observation
              -> Int
              -> m GaussianHMM
kMeansInitial g ob k = do 
    (membership, _) <- kmeans g k ob
    let pi = G.map (log . (/ fromIntegral n)) $ G.create $ do
            vec <- GM.replicate k 0.0001
            V.forM_ membership $ \s -> GM.unsafeRead vec s >>= GM.unsafeWrite vec s . (+1)
            return vec

        trans = M.map log $ MM.create $ do
            mat <- MM.replicate (k,k) 0.0001
            V.sequence_ . V.zipWith ( \i j -> MM.unsafeRead mat (i,j) >>=
                MM.unsafeWrite mat (i,j) . (+1) ) membership . V.tail $
                membership
            normalizeByRow k mat
            return mat
        
        emisson = G.fromList $ map (uncurry mvn . meanCov) clusters
          where
            clusters = map (M.fromRows . snd . unzip) . groupBy ((==) `on` fst) . sortBy (comparing fst) $ zip (G.toList membership) $ M.toRows ob
    return $ GaussianHMM pi trans emisson
  where
    n = M.rows ob
    normalizeByRow x mat = forM_ [0..x-1] $ \i -> do
        sc <- G.foldM' (\acc j -> fmap (+acc) $ MM.unsafeRead mat (i,j)) 0 $ U.enumFromN 0 x
        forM_ [0..x-1] $ \j -> MM.unsafeRead mat (i,j) >>= MM.unsafeWrite mat (i,j) . (/sc)

meanCov dat = (meanVec, reshape p $ M.flatten $ fst $ glasso covs 0.01)
  where
    covs = MM.create $ do
        mat <- MM.new (p,p)
        forM_ [0..p-1] $ \i -> 
            forM_ [i..p-1] $ \j -> do
                let cov = covWithMean (meanVec G.! i, dat `M.takeColumn` i) (meanVec G.! j, dat `M.takeColumn` j) 
                MM.unsafeWrite mat (i,j) cov
                MM.unsafeWrite mat (j,i) cov
        return mat

    meanVec = G.fromList . map mean . M.toColumns $ dat
    p = G.length meanVec

covWithMean :: (Double, Vector Double) -> (Double, Vector Double) -> Double
covWithMean (mx, xs) (my, ys) | n == 1 = 0
                              | otherwise = G.sum (G.zipWith f xs ys) / (n - 1)
  where
    f x y = (x - mx) * (y - my)
    n = fromIntegral $ G.length xs

convert mat = reshape c $ M.flatten mat
  where
    c = M.cols mat

hmmExample :: (GaussianHMM, Observation)
hmmExample = (hmm, obs)
  where
    hmm = GaussianHMM (U.fromList $ map log [0.5,0.5])
                      (M.fromLists $ ((map.map) log) [[0.1,0.9],[0.5,0.5]])
                      (V.fromList [m1,m2])
    m1 = mvn (vector [1]) (matrix 1 [1])
    m2 = mvn (vector [-1]) (matrix 1 [1])
    obs = M.fromLists $ map return [ -1.6835, 0.0635, -2.1688, 0.3043, -0.3188
                                   , -0.7835, 1.0398, -1.3558, 1.0882, 0.4050 ]


test = do
    let (hmm, obs) = hmmExample
    loop obs hmm 0
  where
    loop o h i | i > 20 = 1
               | otherwise = let h' = fst $ baumWelch o h
                                 (f, sc) = forward h o
                             in traceShow (G.sum sc) $ loop o h' (i+1)