{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module SpaceTrack.Config
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

data Config = Config
  { cfgSpaceTrackUsernameFile :: !FilePath
  , cfgSpaceTrackPasswordFile :: !FilePath
  , cfgDatabaseUrl :: !(Maybe String)
  , cfgDatabaseUrlFile :: !(Maybe FilePath)
  , cfgDatabaseHost :: !String
  , cfgDatabaseName :: !String
  , cfgDatabaseUser :: !String
  , cfgQueryUrl :: !String
  , cfgRequestTimeoutSeconds :: !Int
  , cfgMaxRetries :: !Int
  , cfgThrottlePerMinute :: !Int
  , cfgThrottlePerHour :: !Int
  , cfgThrottleMinSpacingSeconds :: !Double
  , cfgDryRun :: !Bool
  }
  deriving (Eq, Show)

parseConfig :: IO Config
parseConfig =
  execParser $
    info
      (helper <*> configParser)
      ( fullDesc
          <> progDesc "Fetch Space-Track GP records whose periapsis enters LEO and store the latest record per object."
          <> header "spacetrack-leo-ingest"
      )

configParser :: Parser Config
configParser = do
  cfgSpaceTrackUsernameFile <-
    strOption
      ( long "spacetrack-username-file"
          <> metavar "PATH"
          <> help "Path to a file containing the Space-Track username."
      )
  cfgSpaceTrackPasswordFile <-
    strOption
      ( long "spacetrack-password-file"
          <> metavar "PATH"
          <> help "Path to a file containing the Space-Track password."
      )
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
  cfgQueryUrl <-
    strOption
      ( long "query-url"
          <> metavar "URL"
          <> value defaultQueryUrl
          <> showDefault
          <> help "Space-Track GP query URL."
      )
  cfgRequestTimeoutSeconds <-
    option
      auto
      ( long "request-timeout-seconds"
          <> metavar "SECONDS"
          <> value 180
          <> showDefault
          <> help "HTTP request timeout in seconds."
      )
  cfgMaxRetries <-
    option
      auto
      ( long "max-retries"
          <> metavar "N"
          <> value 5
          <> showDefault
          <> help "Maximum retries for transient HTTP/network failures."
      )
  cfgThrottlePerMinute <-
    option
      auto
      ( long "throttle-per-minute"
          <> metavar "N"
          <> value 25
          <> showDefault
          <> help "Proactive request cap per rolling minute."
      )
  cfgThrottlePerHour <-
    option
      auto
      ( long "throttle-per-hour"
          <> metavar "N"
          <> value 270
          <> showDefault
          <> help "Proactive request cap per rolling hour."
      )
  cfgThrottleMinSpacingSeconds <-
    option
      (maybeReader readMaybeDouble)
      ( long "throttle-min-spacing-seconds"
          <> metavar "SECONDS"
          <> value 2.5
          <> showDefault
          <> help "Minimum spacing between Space-Track requests."
      )
  cfgDryRun <-
    switch
      ( long "dry-run"
          <> help "Fetch and validate Space-Track data without mutating the database."
      )
  pure Config {..}

defaultQueryUrl :: String
defaultQueryUrl =
  "https://www.space-track.org/basicspacedata/query/class/gp/DECAY_DATE/null-val/EPOCH/%3Enow-10/PERIAPSIS/%3C2000/orderby/NORAD_CAT_ID%20asc/format/json/emptyresult/show"

trimSecret :: String -> String
trimSecret = dropWhileEnd isSpace . dropWhile isSpace

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd predicate = reverse . dropWhile predicate . reverse

readMaybeDouble :: String -> Maybe Double
readMaybeDouble text =
  case reads text of
    [(number, "")] -> Just number
    _ -> Nothing
