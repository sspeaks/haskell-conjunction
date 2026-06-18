{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- | Configuration and command-line parsing for the @conjunction-api@ server.
--
-- The database connection conventions mirror those of the @conjunction-screen@
-- executable (@--database-url@ / @--database-url-file@ / host+name+user) so the
-- API can be pointed at the same PostgreSQL instance the screener writes to.
module Api.Config
  ( Config (..)
  , parseConfig
  , connectionString
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
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
  , value
  , (<**>)
  )

-- | Fully resolved server configuration.
data Config = Config
  { cfgPort :: !Int
  -- ^ TCP port the HTTP server binds to.
  , cfgStaticDir :: !FilePath
  -- ^ Directory of the built frontend served for non-@/api@ paths.
  , cfgDatabaseUrl :: !(Maybe String)
  -- ^ Full libpq connection string, taking precedence over host/name/user.
  , cfgDatabaseUrlFile :: !(Maybe FilePath)
  -- ^ Path to a file containing the connection string (highest precedence).
  , cfgDatabaseHost :: !String
  , cfgDatabaseName :: !String
  , cfgDatabaseUser :: !String
  }
  deriving (Eq, Show)

-- | Parse configuration from the command line.
parseConfig :: IO Config
parseConfig =
  execParser $
    info
      (configParser <**> helper)
      ( fullDesc
          <> progDesc "Read-only JSON API serving satellites and conjunction events."
          <> header "conjunction-api - visualization backend for haskell-conjunction"
      )

configParser :: Parser Config
configParser = do
  cfgPort <-
    option
      auto
      (long "port" <> metavar "PORT" <> value 8080 <> showDefault <> help "HTTP listen port")
  cfgStaticDir <-
    strOption
      ( long "static-dir"
          <> metavar "DIR"
          <> value "web/dist"
          <> showDefault
          <> help "Directory of the built frontend to serve"
      )
  cfgDatabaseUrl <-
    optional
      (strOption (long "database-url" <> metavar "URL" <> help "libpq connection string"))
  cfgDatabaseUrlFile <-
    optional
      ( strOption
          ( long "database-url-file"
              <> metavar "PATH"
              <> help "File containing a libpq connection string"
          )
      )
  cfgDatabaseHost <-
    strOption
      ( long "database-host"
          <> metavar "HOST"
          <> value "localhost"
          <> showDefault
          <> help "PostgreSQL host (used when no URL is given)"
      )
  cfgDatabaseName <-
    strOption
      ( long "database-name"
          <> metavar "NAME"
          <> value "spacetrack-ingest"
          <> showDefault
          <> help "PostgreSQL database name"
      )
  cfgDatabaseUser <-
    strOption
      ( long "database-user"
          <> metavar "USER"
          <> value "spacetrack-ingest"
          <> showDefault
          <> help "PostgreSQL user"
      )
  pure Config {..}

-- | Resolve the libpq connection string from the configuration.
connectionString :: Config -> IO ByteString
connectionString Config {..} =
  case (cfgDatabaseUrlFile, cfgDatabaseUrl) of
    (Just path, _) -> BS8.pack . trimSecret <$> readFile path
    (Nothing, Just url) -> pure (BS8.pack url)
    (Nothing, Nothing) ->
      pure $
        BS8.pack $
          "host="
            <> cfgDatabaseHost
            <> " dbname="
            <> cfgDatabaseName
            <> " user="
            <> cfgDatabaseUser

-- | Strip leading and trailing whitespace (e.g. a trailing newline from a
-- secret file).
trimSecret :: String -> String
trimSecret = f . f
  where
    f = reverse . dropWhile isSpace
