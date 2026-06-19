{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- | Command-line configuration for @conjunction-notify@.
--
-- The flag conventions mirror "ConjunctionScreen.Config": the same database
-- selection set, secrets supplied through files rather than on the command line,
-- and @optparse-applicative@ defaults shown in @--help@.
module ConjunctionNotify.Config
  ( Config (..)
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
  , metavar
  , option
  , optional
  , progDesc
  , showDefault
  , strOption
  , switch
  , value
  )

data Config = Config
  { cfgDatabaseUrl :: !(Maybe String)
  , cfgDatabaseUrlFile :: !(Maybe FilePath)
  , cfgDatabaseHost :: !String
  , cfgDatabaseName :: !String
  , cfgDatabaseUser :: !String
  , cfgObserverLatDeg :: !Double
  , cfgObserverLonDeg :: !Double
  , cfgObserverHeightKm :: !Double
  , cfgWindowHours :: !Double
  , cfgMinElevationDeg :: !Double
  , cfgSunMaxElevationDeg :: !Double
  , cfgMagnitudeCutoff :: !Double
  , cfgNtfyServer :: !String
  , cfgNtfyTopic :: !String
  , cfgNtfyTokenFile :: !(Maybe FilePath)
  , cfgNtfyPriority :: !(Maybe String)
  , cfgNtfyTitle :: !String
  , cfgNtfyTags :: !String
  , cfgWatchLabel :: !(Maybe String)
  , cfgDryRun :: !Bool
  }
  deriving (Eq, Show)

parseConfig :: IO Config
parseConfig =
  execParser $
    info
      (helper <*> configParser)
      ( fullDesc
          <> progDesc
            "Notify a configured observer, via an ntfy topic, of naked-eye-visible \
            \conjunctions occurring in the next window."
          <> header "conjunction-notify"
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
  cfgObserverLatDeg <-
    option
      auto
      ( long "observer-lat"
          <> metavar "DEG"
          <> help "Observer WGS84 latitude in degrees (north positive). Required."
      )
  cfgObserverLonDeg <-
    option
      auto
      ( long "observer-lon"
          <> metavar "DEG"
          <> help "Observer WGS84 longitude in degrees (east positive). Required."
      )
  cfgObserverHeightKm <-
    option
      auto
      ( long "observer-height-km"
          <> metavar "KM"
          <> value 0.0
          <> showDefault
          <> help "Observer height above the WGS84 ellipsoid in kilometers."
      )
  cfgWindowHours <-
    option
      auto
      ( long "window-hours"
          <> metavar "HOURS"
          <> value 24.0
          <> showDefault
          <> help "Look-ahead horizon: notify for conjunctions whose TCA is within this many hours."
      )
  cfgMinElevationDeg <-
    option
      auto
      ( long "min-elevation-deg"
          <> metavar "DEG"
          <> value 10.0
          <> showDefault
          <> help "Minimum peak elevation above the horizon for a conjunction to count as visible."
      )
  cfgSunMaxElevationDeg <-
    option
      auto
      ( long "sun-max-elevation-deg"
          <> metavar "DEG"
          <> value (-6.0)
          <> showDefault
          <> help "Observer is dark when the Sun is below this elevation (use the --flag=-6 form for negatives)."
      )
  cfgMagnitudeCutoff <-
    option
      auto
      ( long "magnitude-cutoff"
          <> metavar "MAG"
          <> value 6.5
          <> showDefault
          <> help "Faintest apparent magnitude still worth a notification (larger = fainter)."
      )
  cfgNtfyServer <-
    strOption
      ( long "ntfy-server"
          <> metavar "URL"
          <> value "https://ntfy.sh"
          <> showDefault
          <> help "Base URL of the ntfy server. Override for a self-hosted instance."
      )
  cfgNtfyTopic <-
    strOption
      ( long "ntfy-topic"
          <> metavar "TOPIC"
          <> help "ntfy topic to publish to. Required. Subscribe to this topic on your phone."
      )
  cfgNtfyTokenFile <-
    optional $
      strOption
        ( long "ntfy-token-file"
            <> metavar "PATH"
            <> help "Path to a file containing an ntfy access token (sent as a Bearer token)."
        )
  cfgNtfyPriority <-
    optional $
      strOption
        ( long "ntfy-priority"
            <> metavar "PRIORITY"
            <> help "Optional ntfy message priority (max|high|default|low|min or 1-5)."
        )
  cfgNtfyTitle <-
    strOption
      ( long "ntfy-title"
          <> metavar "TEXT"
          <> value "Visible satellite conjunction"
          <> showDefault
          <> help "Title applied to each ntfy notification."
      )
  cfgNtfyTags <-
    strOption
      ( long "ntfy-tags"
          <> metavar "TAGS"
          <> value "telescope,satellite"
          <> showDefault
          <> help "Comma-separated ntfy tags/emoji shortcodes applied to each notification."
      )
  cfgWatchLabel <-
    optional $
      strOption
        ( long "watch-label"
            <> metavar "LABEL"
            <> help "De-duplication key recorded per notification. Defaults to the ntfy topic."
        )
  cfgDryRun <-
    switch
      ( long "dry-run"
          <> help "Print the notifications that would be sent instead of POSTing them or recording them."
      )
  pure Config {..}

-- | Strip surrounding whitespace from a secret read from a file.
trimSecret :: String -> String
trimSecret = dropWhileEnd isSpace . dropWhile isSpace

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd predicate = reverse . dropWhile predicate . reverse
