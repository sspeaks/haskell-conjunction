{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

module ConjunctionScreen.Config
  ( Config (..)
  , ScreenMode (..)
  , parseConfig
  , trimSecret
  ) where

import Data.Char (isSpace)
import Options.Applicative
  ( Parser
  , auto
  , execParser
  , fullDesc
  , header
  , help
  , helper
  , info
  , long
  , maybeReader
  , metavar
  , option
  , optional
  , progDesc
  , showDefault
  , strOption
  , switch
  , value
  )

-- | Which algorithm to run.
data ScreenMode
  = -- | Optimized spatial-hash screen; persists results (production path).
    ModeOptimized
  | -- | Raw all-pairs CM-COMBO screen; persists results. Slow on large catalogs.
    ModeRaw
  | -- | Run both on a bounded subset, report agreement, persist nothing.
    ModeValidate
  deriving (Eq, Show)

data Config = Config
  { cfgDatabaseUrl :: !(Maybe String)
  , cfgDatabaseUrlFile :: !(Maybe FilePath)
  , cfgDatabaseHost :: !String
  , cfgDatabaseName :: !String
  , cfgDatabaseUser :: !String
  , cfgWindowHours :: !Double
  , cfgStepSeconds :: !Double
  , cfgThresholdKm :: !Double
  , cfgCoarseThresholdKm :: !(Maybe Double)
  , cfgRelVelMaxKms :: !Double
  , cfgRefineStepSeconds :: !Double
  , cfgMinRelativeSpeedKms :: !Double
  , cfgTileHours :: !(Maybe Double)
  , cfgMode :: !ScreenMode
  , cfgValidateLimit :: !Int
  , cfgSkipIfComputedToday :: !Bool
  }
  deriving (Eq, Show)

parseConfig :: IO Config
parseConfig =
  execParser $
    info
      (helper <*> configParser)
      ( fullDesc
          <> progDesc
            "Screen the active LEO catalog for close approaches and store the conjunctions for the day."
          <> header "conjunction-screen"
      )

configParser :: Parser Config
configParser = do
  cfgDatabaseUrl <-
    optional $
      strOption
        ( long "database-url"
            <> metavar "CONNINFO"
            <> help "PostgreSQL connection string. Prefer --database-url-file for secrets."
        )
  cfgDatabaseUrlFile <-
    optional $
      strOption
        ( long "database-url-file"
            <> metavar "PATH"
            <> help "Path to a file containing a PostgreSQL connection string."
        )
  cfgDatabaseHost <-
    strOption
      ( long "database-host"
          <> metavar "HOST"
          <> value "/run/postgresql"
          <> showDefault
          <> help "PostgreSQL host or Unix socket directory for local database mode."
      )
  cfgDatabaseName <-
    strOption
      ( long "database-name"
          <> metavar "NAME"
          <> value "spacetrack_leo"
          <> showDefault
          <> help "PostgreSQL database name for local database mode."
      )
  cfgDatabaseUser <-
    strOption
      ( long "database-user"
          <> metavar "USER"
          <> value "spacetrack-ingest"
          <> showDefault
          <> help "PostgreSQL user for local database mode."
      )
  cfgWindowHours <-
    option
      auto
      ( long "window-hours"
          <> metavar "HOURS"
          <> value 24.0
          <> showDefault
          <> help "Screening horizon length in hours."
      )
  cfgStepSeconds <-
    option
      auto
      ( long "step-seconds"
          <> metavar "SECONDS"
          <> value 10.0
          <> showDefault
          <> help
            "Coarse propagation sampling step in seconds. Smaller steps shrink the\
            \ derived coarse gate and so the candidate set, at the cost of more\
            \ propagation; combine with --tile-hours to bound memory."
      )
  cfgThresholdKm <-
    option
      auto
      ( long "threshold-km"
          <> metavar "KM"
          <> value 5.0
          <> showDefault
          <> help "Final reported miss-distance threshold in kilometers."
      )
  cfgCoarseThresholdKm <-
    optional $
      option
        auto
        ( long "coarse-threshold-km"
            <> metavar "KM"
            <> help "Override the derived coarse candidate gate in kilometers."
        )
  cfgRelVelMaxKms <-
    option
      auto
      ( long "rel-vel-max-kms"
          <> metavar "KM_S"
          <> value 15.6
          <> showDefault
          <> help "Maximum relative velocity used to derive the coarse threshold."
      )
  cfgRefineStepSeconds <-
    option
      auto
      ( long "refine-step-seconds"
          <> metavar "SECONDS"
          <> value 1.0
          <> showDefault
          <> help "Fine step used to refine each candidate's time of closest approach."
      )
  cfgMinRelativeSpeedKms <-
    option
      auto
      ( long "min-relative-speed-kms"
          <> metavar "KM_S"
          <> value 0.1
          <> showDefault
          <> help
            "Suppress co-orbital/co-located pairs whose relative speed at closest\
            \ approach is below this floor (km/s); 0 disables."
      )
  cfgTileHours <-
    optional $
      option
        auto
        ( long "tile-hours"
            <> metavar "HOURS"
            <> help
              "Screen the window in consecutive tiles of this many hours so only one\
              \ tile's propagation table is resident at a time, bounding peak memory.\
              \ Defaults to 1 hour; pass a value at least the window length to screen\
              \ the whole window at once."
        )
  cfgMode <-
    option
      (maybeReader readMode)
      ( long "mode"
          <> metavar "optimized|raw|validate"
          <> value ModeOptimized
          <> showDefault
          <> help "Screening mode. The optimized mode is the production path."
      )
  cfgValidateLimit <-
    option
      auto
      ( long "validate-limit"
          <> metavar "N"
          <> value 500
          <> showDefault
          <> help "Maximum objects compared in validate mode (raw is quadratic)."
      )
  cfgSkipIfComputedToday <-
    switch
      ( long "skip-if-computed-today"
          <> help "Exit without screening when a successful run already finished today."
      )
  pure Config {..}

readMode :: String -> Maybe ScreenMode
readMode "optimized" = Just ModeOptimized
readMode "raw" = Just ModeRaw
readMode "validate" = Just ModeValidate
readMode _ = Nothing

trimSecret :: String -> String
trimSecret = dropWhileEnd isSpace . dropWhile isSpace

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd predicate = reverse . dropWhile predicate . reverse
