{-# LANGUAGE BangPatterns #-}

-- | The shared screening engine used by both conjunction algorithms.
--
-- 'prepare' batch-propagates every catalog object across the absolute-UTC time
-- grid and records, per step, the present objects' TEME positions plus each
-- object's radial band. The raw and optimized algorithms differ only in how
-- they turn this table into candidate pairs; everything downstream — candidate
-- reduction and time-of-closest-approach refinement — is shared here, so the
-- two algorithms necessarily produce identical events.
module Conjunction.Screen
  ( Prepared (..)
  , prepare
  , coarseThresholdKm
  , reduceCandidates
  , refineCandidates
  , screenWith
  , v3X
  , v3Y
  , v3Z
  ) where

import Conjunction.Catalog (timeGrid)
import Conjunction.Parallel (parMapIO)
import Conjunction.Progress
  ( Counter
  , finishCounter
  , logInfo
  , newCounter
  , tick
  , withPhase
  )
import Conjunction.Types
  ( CatalogObject (..)
  , ConjunctionEvent (..)
  , GeoPoint (..)
  , ObjectState (..)
  , ScreenConfig (..)
  )
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.Array (Array, listArray, (!))
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Linear.Metric (norm)
import Linear.V3 (V3 (V3))
import Linear.Vector ((^+^), (^-^), (^/))
import SGP4
  ( StateVector (..)
  , propagateMany
  )
import SGP4.Coordinate
  ( GeodeticPosition (GeodeticPosition)
  , Kilometers (Km)
  , Radians (Radians)
  , TEMEPosition (TEMEPosition)
  , vec3ToV3
  , v3ToVec3
  )
import SGP4.Frames (ecefToGeodetic, temeToEcef)
import SGP4.Time
  ( SplitJD
  , diffDays
  , gmst
  , satelliteEpochSJD
  , utcToSplitJD
  )
import Text.Printf (printf)

-- | The propagated screening table.
data Prepared = Prepared
  { prepObjects :: !(Array Int CatalogObject)
  -- ^ Catalog objects indexed @0 .. prepCount - 1@.
  , prepEpochs :: !(Array Int SplitJD)
  -- ^ Each object's TLE epoch, used to derive @tsince@ during refinement.
  , prepGrid :: !(Array Int UTCTime)
  -- ^ Absolute UTC sample times indexed @0 .. prepSteps - 1@.
  , prepColumns :: !(Array Int [(Int, V3 Double)])
  -- ^ Per step, the present objects as @(objectIndex, temePositionKm)@.
  , prepRadial :: !(Array Int (Maybe (Double, Double)))
  -- ^ Per object, the @(minRadius, maxRadius)@ band over present samples.
  , prepCount :: !Int
  , prepSteps :: !Int
  }

-- | Coarse candidate gate in kilometers.
--
-- When the configuration does not pin a value, it is derived so that any
-- approach within the final threshold is detected at an adjacent sample even
-- for the fastest head-on encounter: @threshold + relVelMax * step / 2@.
coarseThresholdKm :: ScreenConfig -> Double
coarseThresholdKm cfg =
  fromMaybe derived (scCoarseThresholdKm cfg)
 where
  derived = scThresholdKm cfg + scRelVelMaxKms cfg * (scStepSeconds cfg / 2.0)

-- | Propagate the whole catalog across the time grid.
prepare :: ScreenConfig -> [CatalogObject] -> IO Prepared
prepare cfg objs = do
  let count = length objs
      times = timeGrid cfg
      steps = length times
      timeSjds = map utcToSplitJD times
  epochs <- parMapIO (satelliteEpochSJD . coSatellite) objs
  let epochArr = listArray (0, count - 1) epochs
  logInfo (printf "prepare: propagating %d objects over %d time steps" count steps)
  propagateCounter <- newCounter "propagate" count
  perObject <-
    parMapIO (propagateTracked propagateCounter epochArr timeSjds) (zip [0 ..] objs)
  finishCounter propagateCounter
  let sampleArr =
        listArray (0, count - 1) (map (listArray (0, steps - 1)) perObject) ::
          Array Int (Array Int (Maybe (V3 Double, V3 Double)))
      columns =
        [ [(i, fst s) | i <- [0 .. count - 1], Just s <- [sampleArr ! i ! k]]
        | k <- [0 .. steps - 1]
        ]
      radial =
        [ radialBand [fst s | k <- [0 .. steps - 1], Just s <- [sampleArr ! i ! k]]
        | i <- [0 .. count - 1]
        ]
  pure
    Prepared
      { prepObjects = listArray (0, count - 1) objs
      , prepEpochs = epochArr
      , prepGrid = listArray (0, steps - 1) times
      , prepColumns = listArray (0, steps - 1) columns
      , prepRadial = listArray (0, count - 1) radial
      , prepCount = count
      , prepSteps = steps
      }

toSample :: Either e StateVector -> Maybe (V3 Double, V3 Double)
toSample (Right (StateVector pos vel _)) = Just (vec3ToV3 pos, vec3ToV3 vel)
toSample (Left _) = Nothing

-- | Propagate one object and force its samples to normal form.
--
-- Forcing here makes the propagation phase perform the real work (rather than
-- deferring it lazily into later phases), so the reported propagation progress
-- reflects genuine completion. The progress counter is ticked once the object's
-- samples are fully realized.
propagateTracked ::
  Counter ->
  Array Int SplitJD ->
  [SplitJD] ->
  (Int, CatalogObject) ->
  IO [Maybe (V3 Double, V3 Double)]
propagateTracked counter epochArr timeSjds entry = do
  samples <- propagateObject epochArr timeSjds entry
  !forced <- evaluate (force samples)
  tick counter
  pure forced

-- | Batch-propagate one object across the grid, in absolute-UTC order.
propagateObject ::
  Array Int SplitJD ->
  [SplitJD] ->
  (Int, CatalogObject) ->
  IO [Maybe (V3 Double, V3 Double)]
propagateObject epochArr timeSjds (i, obj) = do
  let epoch = epochArr ! i
      tsinces = [diffDays sjd epoch * 1440.0 | sjd <- timeSjds]
  results <- propagateMany (coSatellite obj) tsinces
  pure (map toSample results)

radialBand :: [V3 Double] -> Maybe (Double, Double)
radialBand [] = Nothing
radialBand (p : ps) = Just (foldl' step (r0, r0) ps)
 where
  r0 = norm p
  step (!lo, !hi) q = let r = norm q in (min lo r, max hi r)

-- | Collapse raw candidate samples to one bracket step per pair.
--
-- For each pair, the retained step is the one with the smallest sampled
-- separation. Both algorithms feed identical sample lists through this
-- reduction, yielding identical bracket steps.
reduceCandidates :: [((Int, Int), Double, Int)] -> Map.Map (Int, Int) Int
reduceCandidates xs = Map.map snd (foldl' ins Map.empty xs)
 where
  ins m (pair, dist, step) = Map.insertWith keepMin pair (dist, step) m
  keepMin new old = if fst new < fst old then new else old

-- | Refine each candidate pair to its true time of closest approach.
--
-- Both objects are re-propagated at the fine refinement step across the bracket
-- window; the minimum-distance fine sample becomes the reported approach. Only
-- approaches within the final threshold are emitted.
refineCandidates :: ScreenConfig -> Prepared -> Map.Map (Int, Int) Int -> IO [ConjunctionEvent]
refineCandidates cfg prep cands = do
  let pairs = Map.toList cands
  counter <- newCounter "refine" (length pairs)
  results <- parMapIO (refineTracked counter) pairs
  finishCounter counter
  pure (catMaybes results)
 where
  refineTracked counter pair = do
    result <- refineOne pair
    tick counter
    pure result
  refineOne ((i, j), k) = do
    let objI = prepObjects prep ! i
        objJ = prepObjects prep ! j
        epochI = prepEpochs prep ! i
        epochJ = prepEpochs prep ! j
        steps = prepSteps prep
        kLo = max 0 (k - 1)
        kHi = min (steps - 1) (k + 1)
        tLo = prepGrid prep ! kLo
        tHi = prepGrid prep ! kHi
        fineTimes = fineGrid tLo tHi (scRefineStepSeconds cfg)
        sjds = map utcToSplitJD fineTimes
        tsI = [diffDays s epochI * 1440.0 | s <- sjds]
        tsJ = [diffDays s epochJ * 1440.0 | s <- sjds]
    resI <- propagateMany (coSatellite objI) tsI
    resJ <- propagateMany (coSatellite objJ) tsJ
    let paired =
          [ (tm, pI, vI, pJ, vJ)
          | (tm, rI, rJ) <- zip3 fineTimes resI resJ
          , Right (StateVector ppI vvI _) <- [rI]
          , Right (StateVector ppJ vvJ _) <- [rJ]
          , let pI = vec3ToV3 ppI
                vI = vec3ToV3 vvI
                pJ = vec3ToV3 ppJ
                vJ = vec3ToV3 vvJ
          ]
    pure $ case minimumByDistance paired of
      Nothing -> Nothing
      Just (tm, pI, vI, pJ, vJ)
        | norm (pI ^-^ pJ) <= scThresholdKm cfg ->
            Just (buildEvent objI objJ tm pI vI pJ vJ)
        | otherwise -> Nothing

minimumByDistance ::
  [(UTCTime, V3 Double, V3 Double, V3 Double, V3 Double)] ->
  Maybe (UTCTime, V3 Double, V3 Double, V3 Double, V3 Double)
minimumByDistance [] = Nothing
minimumByDistance (x : xs) = Just (foldl' pick x xs)
 where
  pick best candidate = if dist candidate < dist best then candidate else best
  dist (_, pI, _, pJ, _) = norm (pI ^-^ pJ)

-- | Assemble an event with objects in canonical (ascending NORAD id) order.
buildEvent ::
  CatalogObject ->
  CatalogObject ->
  UTCTime ->
  V3 Double ->
  V3 Double ->
  V3 Double ->
  V3 Double ->
  ConjunctionEvent
buildEvent objI objJ tm pI vI pJ vJ =
  ConjunctionEvent
    { ceTca = tm
    , ceMissDistanceKm = norm (pI ^-^ pJ)
    , ceRelativeSpeedKms = norm (vI ^-^ vJ)
    , ceObjectA = stateA
    , ceObjectB = stateB
    , ceMidpoint = geoAt tm ((pI ^+^ pJ) ^/ 2.0)
    }
 where
  stateI = objectStateOf objI tm pI vI
  stateJ = objectStateOf objJ tm pJ vJ
  (stateA, stateB)
    | coNoradId objI <= coNoradId objJ = (stateI, stateJ)
    | otherwise = (stateJ, stateI)

objectStateOf :: CatalogObject -> UTCTime -> V3 Double -> V3 Double -> ObjectState
objectStateOf obj tm pos vel =
  ObjectState
    { osNoradId = coNoradId obj
    , osName = coName obj
    , osPosTeme = v3ToVec3 pos
    , osVelTeme = v3ToVec3 vel
    , osGeo = geoAt tm pos
    }

-- | WGS84 geodetic position of a TEME point at a given absolute time.
geoAt :: UTCTime -> V3 Double -> GeoPoint
geoAt tm pos =
  let siderealTime = gmst (utcToSplitJD tm)
      GeodeticPosition (Radians lat) (Radians lon) (Km alt) =
        ecefToGeodetic (temeToEcef siderealTime (TEMEPosition pos))
   in GeoPoint (lat * 180.0 / pi) (lon * 180.0 / pi) alt

-- | Inclusive fine grid between two absolute times.
fineGrid :: UTCTime -> UTCTime -> Double -> [UTCTime]
fineGrid start end step =
  [addUTCTime (realToFrac (fromIntegral m * step)) start | m <- [0 .. n]]
 where
  spanSeconds = realToFrac (diffUTCTime end start) :: Double
  n = max 0 (floor (spanSeconds / step)) :: Int

-- | Run a screen given a candidate generator.
screenWith ::
  (ScreenConfig -> Prepared -> [((Int, Int), Double, Int)]) ->
  ScreenConfig ->
  [CatalogObject] ->
  IO [ConjunctionEvent]
screenWith generate cfg objs = do
  prep <- prepare cfg objs
  cands <- withPhase "candidates" $ do
    let reduced = reduceCandidates (generate cfg prep)
    !pairCount <- evaluate (Map.size reduced)
    logInfo (printf "candidates: %d bracket pairs to refine" pairCount)
    pure reduced
  refineCandidates cfg prep cands

v3X :: V3 Double -> Double
v3X (V3 x _ _) = x

v3Y :: V3 Double -> Double
v3Y (V3 _ y _) = y

v3Z :: V3 Double -> Double
v3Z (V3 _ _ z) = z
