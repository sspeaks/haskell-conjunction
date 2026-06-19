{-# LANGUAGE BangPatterns #-}

-- | The shared screening engine used by both conjunction algorithms.
--
-- 'prepareTile' batch-propagates every catalog object across one tile of the
-- absolute-UTC time grid and records, per step, the present objects' TEME
-- positions plus each object's radial band. The window is screened tile by tile
-- so only one tile's table is resident at a time. The raw and optimized
-- algorithms differ only in how they turn each tile's table into candidate
-- pairs; everything downstream — candidate reduction and time-of-closest-approach
-- refinement — is shared here, so the two algorithms necessarily produce
-- identical events.
module Conjunction.Screen
  ( Prepared (..)
  , prepareTile
  , coarseThresholdKm
  , tileStepCount
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
import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (mapConcurrently)
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (when)
import Data.Array (Array, bounds, listArray, (!))
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Time (UTCTime, addUTCTime, diffUTCTime)
import Linear.Metric (norm)
import Linear.V3 (V3 (V3))
import Linear.Vector ((^+^), (^-^), (^/))
import SGP4
  ( StateVector (..)
  , Vec3 (..)
  , propagate
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

-- | Propagate the whole catalog across one tile's absolute-UTC sub-grid.
--
-- The tile covers @stepCount@ coarse steps starting at absolute step
-- @stepOffset@; sample times are @scStart + (stepOffset + j) * step@. Object and
-- epoch arrays are shared across tiles so only the per-tile position columns are
-- allocated per tile. Emitted candidate step indices are tile-local
-- (@0 .. stepCount - 1@) and the caller shifts them by @stepOffset@ to recover
-- absolute steps.
prepareTile ::
  ScreenConfig ->
  Array Int CatalogObject ->
  Array Int SplitJD ->
  String ->
  Int ->
  Int ->
  IO Prepared
prepareTile cfg objArr epochArr label stepOffset stepCount = do
  let count = rangeSizeOf objArr
      times =
        [ addUTCTime (realToFrac (fromIntegral (stepOffset + j) * scStepSeconds cfg)) (scStart cfg)
        | j <- [0 .. stepCount - 1]
        ]
      timeSjds = map utcToSplitJD times
  propagateCounter <- newCounter ("propagate" ++ label) count
  perObject <-
    parMapIO
      (propagateTracked propagateCounter epochArr timeSjds)
      [(i, objArr ! i) | i <- [0 .. count - 1]]
  finishCounter propagateCounter
  let sampleArr =
        listArray (0, count - 1) (map (listArray (0, stepCount - 1)) perObject) ::
          Array Int (Array Int (Maybe (V3 Double, V3 Double)))
      columns =
        [ [(i, fst s) | i <- [0 .. count - 1], Just s <- [sampleArr ! i ! k]]
        | k <- [0 .. stepCount - 1]
        ]
      radial =
        [ radialBand [fst s | k <- [0 .. stepCount - 1], Just s <- [sampleArr ! i ! k]]
        | i <- [0 .. count - 1]
        ]
  pure
    Prepared
      { prepObjects = objArr
      , prepEpochs = epochArr
      , prepGrid = listArray (0, stepCount - 1) times
      , prepColumns = listArray (0, stepCount - 1) columns
      , prepRadial = listArray (0, count - 1) radial
      , prepCount = count
      , prepSteps = stepCount
      }

rangeSizeOf :: Array Int a -> Int
rangeSizeOf arr = let (lo, hi) = bounds arr in hi - lo + 1

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

-- | Number of coarse steps to screen per tile.
--
-- Derived from 'scTileHours'; defaults to the whole window (a single tile) and
-- is clamped to @[1, totalSteps]@.
tileStepCount :: ScreenConfig -> Int -> Int
tileStepCount cfg totalSteps =
  case scTileHours cfg of
    Nothing -> max 1 totalSteps
    Just hours -> max 1 (min totalSteps (floor (hours * 3600.0 / scStepSeconds cfg)))

data CandidateRun = CandidateRun
  { crCompleted :: ![Int]
  , crMinDistance :: !Double
  , crMinStep :: !Int
  , crLastStep :: !Int
  }

-- | Fold one tile's per-step candidate samples into per-pair close-approach runs.
--
-- Each batch of per-step lists (sized to the capability count) is forced in
-- parallel and folded into the accumulator in step order, then discarded before
-- the next batch, so only one batch plus the running map is live at once. For
-- each pair, contiguous samples inside the coarse gate form one run; only that
-- run's minimum-distance bracket step is retained. A gap closes the old run and
-- opens a new one, allowing multiple distinct approaches for the same pair.
foldStepBatches ::
  Int ->
  Map.Map (Int, Int) CandidateRun ->
  [[((Int, Int), Double, Int)]] ->
  IO (Map.Map (Int, Int) CandidateRun)
foldStepBatches cap = go
 where
  go !acc [] = pure acc
  go !acc rest = do
    let (batch, more) = splitAt cap rest
    forced <- mapConcurrently (evaluate . force) batch
    let !acc' = foldl' (foldl' ins) acc forced
    go acc' more
  ins m (pair, dist, step) = Map.alter (Just . maybe (openRun [] dist step) (addSample dist step)) pair m
  openRun completed dist step = CandidateRun completed dist step step
  addSample dist step run
    | step == crLastStep run =
        updateRunMin dist step run
    | step == crLastStep run + 1 =
        (updateRunMin dist step run) {crLastStep = step}
    | step > crLastStep run + 1 =
        openRun (crMinStep run : crCompleted run) dist step
    | otherwise = run
  updateRunMin dist step run
    | dist < crMinDistance run = run {crMinDistance = dist, crMinStep = step}
    | otherwise = run

finalizeRun :: CandidateRun -> [Int]
finalizeRun run = reverse (crMinStep run : crCompleted run)

-- | Screen the window tile by tile, accumulating one global candidate map.
--
-- Tiles partition the coarse grid contiguously, so every step is screened
-- exactly once; the global map keeps each pair's in-progress run and completed
-- bracket steps across all tiles. Only the current tile's propagation columns
-- are resident, which bounds peak memory independently of the window length.
screenTiles ::
  (ScreenConfig -> Prepared -> [[((Int, Int), Double, Int)]]) ->
  ScreenConfig ->
  Array Int CatalogObject ->
  Array Int SplitJD ->
  Int ->
  [(Int, Int)] ->
  IO (Map.Map (Int, Int) [Int])
screenTiles generate cfg objArr epochArr numTiles tiles = do
  capabilities <- getNumCapabilities
  acc <- go (max 1 capabilities) Map.empty (zip [1 :: Int ..] tiles)
  pure (Map.map finalizeRun acc)
 where
  go _ !acc [] = pure acc
  go cap !acc ((ti, (stepOffset, stepCount)) : rest) = do
    let label = if numTiles > 1 then printf " (tile %d/%d)" ti numTiles else ""
    tilePrep <- prepareTile cfg objArr epochArr label stepOffset stepCount
    let shifted =
          map (map (\(pair, dist, k) -> (pair, dist, stepOffset + k))) (generate cfg tilePrep)
    !acc' <- foldStepBatches cap acc shifted
    when (numTiles > 1) $
      logInfo (printf "tile %d/%d folded; running candidate pairs %d" ti numTiles (Map.size acc'))
    go cap acc' rest

-- | Number of candidate pairs refined per batch.
--
-- Small enough that one batch's transient fine-propagation garbage is collected
-- before the next batch starts, bounding peak residency. With 420k candidates,
-- batches of @capabilities * 5000@ produce ~5 collections instead of one
-- monolithic GC at the end.
refineBatchSize :: Int -> Int
refineBatchSize capabilities = max 1 capabilities * 5000

-- | Refine each candidate pair to its true time of closest approach.
--
-- Both objects are re-propagated at the fine refinement step across the bracket
-- window; the minimum-distance fine sample becomes the reported approach. Only
-- approaches within the final threshold are emitted.
refineCandidates :: ScreenConfig -> Prepared -> Map.Map (Int, Int) [Int] -> IO [ConjunctionEvent]
refineCandidates cfg prep cands = do
  let pairs = [((i, j), k) | ((i, j), ks) <- Map.toList cands, k <- ks]
  counter <- newCounter "refine" (length pairs)
  capabilities <- getNumCapabilities
  events <- refineBatches counter (refineBatchSize capabilities) pairs []
  finishCounter counter
  pure events
 where
  -- Refine in bounded batches, collapsing each batch with 'catMaybes' before
  -- starting the next. The candidate set dwarfs the actual conjunction count
  -- (the coarse gate admits far more pairs than ever approach within the final
  -- threshold), so holding every pair's @Maybe@ result live at once exhausted
  -- the heap. Forcing each batch to its kept events discards the non-conjunction
  -- results immediately and bounds peak memory to one batch.
  refineBatches _ _ [] acc = pure (concat (reverse acc))
  refineBatches counter bs rest acc = do
    let (batch, more) = splitAt bs rest
    results <- parMapIO (refineTracked counter) batch
    let !kept = catMaybes results
    _ <- evaluate (length kept)
    refineBatches counter bs more (kept : acc)
  refineTracked counter pair = do
    result <- refineOne pair
    tick counter
    pure result
  -- | Refine one candidate pair to its true time of closest approach.
  --
  -- Tsinces are computed directly from the bracket endpoints and object epochs.
  -- After finding the minimum sampled distance, an analytical TCA is computed
  -- from the relative position and velocity at the minimum sample: near TCA the
  -- relative motion is nearly linear, so the true closest-approach time is
  -- @t_m − (Δr·Δv)/|Δv|²@ and the true minimum distance is @|Δr×Δv|/|Δv|@.
  -- Both objects are then re-propagated to the analytical TCA for the final
  -- reported positions, guaranteeing that conjunctions are not missed due to
  -- discrete sampling.
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
        refineStep = scRefineStepSeconds cfg
        spanSeconds = realToFrac (diffUTCTime tHi tLo) :: Double
        nFine = max 0 (floor (spanSeconds / refineStep)) :: Int
        sjdLo = utcToSplitJD tLo
        baseTsinceI = diffDays sjdLo epochI * 1440.0
        baseTsinceJ = diffDays sjdLo epochJ * 1440.0
        stepMin = refineStep / 60.0
        tsI = [baseTsinceI + fromIntegral m * stepMin | m <- [0 .. nFine]]
        tsJ = [baseTsinceJ + fromIntegral m * stepMin | m <- [0 .. nFine]]
        -- Maximum error between sampled and true minimum distance. Any sampled
        -- distance within this margin of the threshold could hide a real
        -- conjunction, so the analytical TCA check is applied.
        refineSafety = scRelVelMaxKms cfg * refineStep / 2.0
    resI <- propagateMany (coSatellite objI) tsI
    resJ <- propagateMany (coSatellite objJ) tsJ
    case closestApproach resI resJ of
      Nothing -> pure Nothing
      Just (d, m, ppI, vvI, ppJ, vvJ)
        -- Sampled distance is well beyond threshold even accounting for
        -- sampling error — skip without further analysis.
        | d > scThresholdKm cfg + refineSafety -> pure Nothing
        | otherwise -> do
            -- Analytical TCA: at the minimum sample, relative motion is nearly
            -- linear. The time offset to the true closest approach is
            -- −(Δr·Δv)/|Δv|², clamped to ±refineStep.
            let !drx = vecX ppI - vecX ppJ
                !dry = vecY ppI - vecY ppJ
                !drz = vecZ ppI - vecZ ppJ
                !dvx = vecX vvI - vecX vvJ
                !dvy = vecY vvI - vecY vvJ
                !dvz = vecZ vvI - vecZ vvJ
                !dvdv = dvx * dvx + dvy * dvy + dvz * dvz
                !drdv = drx * dvx + dry * dvy + drz * dvz
                !tOff =
                  if dvdv > 1.0e-30
                    then max (-refineStep) (min refineStep (negate drdv / dvdv))
                    else 0.0
                -- Analytical minimum distance estimate (linear extrapolation).
                !erx = drx + tOff * dvx
                !ery = dry + tOff * dvy
                !erz = drz + tOff * dvz
                !dEst = sqrt (erx * erx + ery * ery + erz * erz)
            if dEst > scThresholdKm cfg
              then pure Nothing
              else do
                -- Propagate both objects to the analytical TCA for accurate
                -- event data. This costs two single-step propagations but only
                -- runs for the small fraction of candidates near threshold.
                let tsinceI = baseTsinceI + fromIntegral m * stepMin + tOff / 60.0
                    tsinceJ = baseTsinceJ + fromIntegral m * stepMin + tOff / 60.0
                rI <- propagate (coSatellite objI) tsinceI
                rJ <- propagate (coSatellite objJ) tsinceJ
                pure $ case (rI, rJ) of
                  (Right (StateVector pI' vI' _), Right (StateVector pJ' vJ' _))
                    | vecDist pI' pJ' <= scThresholdKm cfg ->
                        let tm = addUTCTime (realToFrac (fromIntegral m * refineStep + tOff)) tLo
                         in Just (buildEvent objI objJ tm (vec3ToV3 pI') (vec3ToV3 vI') (vec3ToV3 pJ') (vec3ToV3 vJ'))
                  _ -> Nothing

-- | Find the closest approach from two parallel result lists. Returns the
-- minimum distance, winning step index, and raw Vec3 position/velocity for
-- both objects — deferring 'vec3ToV3' conversion to the caller so only the
-- winning sample pays for it.
closestApproach ::
  [Either e StateVector] ->
  [Either e StateVector] ->
  Maybe (Double, Int, Vec3, Vec3, Vec3, Vec3)
closestApproach = go Nothing 0
 where
  go !best !_ [] _ = best
  go !best !_ _ [] = best
  go !best !m (rI : rIs) (rJ : rJs) = case (rI, rJ) of
    (Right (StateVector ppI vvI _), Right (StateVector ppJ vvJ _)) ->
      let !d = vecDist ppI ppJ
       in case best of
            Just (bestD, _, _, _, _, _) | d >= bestD -> go best (m + 1) rIs rJs
            _ -> go (Just (d, m, ppI, vvI, ppJ, vvJ)) (m + 1) rIs rJs
    _ -> go best (m + 1) rIs rJs

-- | Euclidean distance between two Vec3 values without allocating a V3.
vecDist :: Vec3 -> Vec3 -> Double
vecDist (Vec3 x1 y1 z1) (Vec3 x2 y2 z2) =
  let !dx = x1 - x2
      !dy = y1 - y2
      !dz = z1 - z2
   in sqrt (dx * dx + dy * dy + dz * dz)

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

-- | Keep an event only when its relative speed at closest approach is at or
-- above the configured floor.
--
-- A floor of @0.0@ keeps every event (an exact no-op, since relative speed is
-- always non-negative); a positive floor drops near-zero-relative-speed
-- co-orbital/co-located pairs, which share an orbit and so have no single
-- physically meaningful time of closest approach.
keepEvent :: ScreenConfig -> ConjunctionEvent -> Bool
keepEvent cfg event = ceRelativeSpeedKms event >= scMinRelativeSpeedKms cfg

-- | Run a screen given a candidate generator.
screenWith ::
  (ScreenConfig -> Prepared -> [[((Int, Int), Double, Int)]]) ->
  ScreenConfig ->
  [CatalogObject] ->
  IO [ConjunctionEvent]
screenWith generate cfg objs = do
  let n = length objs
      objArr = listArray (0, n - 1) objs
      fullTimes = timeGrid cfg
      totalSteps = length fullTimes
  epochs <- parMapIO (satelliteEpochSJD . coSatellite) objs
  let epochArr = listArray (0, n - 1) epochs
      tileSteps = tileStepCount cfg totalSteps
      tiles = [(lo, min tileSteps (totalSteps - lo)) | lo <- [0, tileSteps .. totalSteps - 1]]
      numTiles = length tiles
  logInfo
    ( printf
        "screen: %d objects, %d steps, %d tile(s) of <=%d steps"
        n
        totalSteps
        numTiles
        tileSteps
    )
  cands <- withPhase "candidates" (screenTiles generate cfg objArr epochArr numTiles tiles)
  let bracketCount = sum (map length (Map.elems cands))
  logInfo (printf "candidates: %d bracket(s) across %d pair(s) to refine" bracketCount (Map.size cands))
  let refineCtx =
        Prepared
          { prepObjects = objArr
          , prepEpochs = epochArr
          , prepGrid = listArray (0, totalSteps - 1) fullTimes
          , prepColumns = listArray (0, -1) []
          , prepRadial = listArray (0, -1) []
          , prepCount = n
          , prepSteps = totalSteps
          }
  events <- refineCandidates cfg refineCtx cands
  let kept = filter (keepEvent cfg) events
      minRelSpeed = scMinRelativeSpeedKms cfg
  when (minRelSpeed > 0) $
    logInfo
      ( printf
          "suppressed %d co-orbital event(s) below %g km/s relative speed"
          (length events - length kept)
          minRelSpeed
      )
  pure kept

v3X :: V3 Double -> Double
v3X (V3 x _ _) = x

v3Y :: V3 Double -> Double
v3Y (V3 _ y _) = y

v3Z :: V3 Double -> Double
v3Z (V3 _ _ z) = z
