{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module SpaceTrack.Client (fetchCurrentLeoGp) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, SomeException, throwIO, try)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Network.HTTP.Client
  ( CookieJar
  , Manager
  , Request
  , Response
  , createCookieJar
  , httpLbs
  , parseRequest
  , cookieJar
  , requestHeaders
  , responseBody
  , responseCookieJar
  , responseStatus
  , responseTimeout
  , responseTimeoutMicro
  , urlEncodedBody
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import SpaceTrack.Config (Config (..), trimSecret)
import SpaceTrack.Json (decodeGpRecords)
import SpaceTrack.Throttle
  ( RateLimiter
  , acquire
  , newRateLimiter
  )
import SpaceTrack.Types (GpRecord)

data SpaceTrackError
  = AuthenticationFailed
  | HttpRequestFailed !Int !T.Text
  | NetworkRequestFailed !String
  | TooManyRetries !String
  deriving (Eq, Show)

instance Exception SpaceTrackError

fetchCurrentLeoGp :: Config -> IO [GpRecord]
fetchCurrentLeoGp config@Config {..} = do
  username <- trimSecret <$> readFile cfgSpaceTrackUsernameFile
  password <- trimSecret <$> readFile cfgSpaceTrackPasswordFile
  manager <- newTlsManager
  limiter <- newRateLimiter cfgThrottlePerMinute cfgThrottlePerHour cfgThrottleMinSpacingSeconds
  loginResponse <- login manager limiter config username password
  let jar = responseCookieJar loginResponse
  gpResponse <- getWithCookies manager limiter config jar cfgQueryUrl
  records <- decodeGpRecords (responseBody gpResponse)
  _ <- logout manager limiter config (responseCookieJar gpResponse)
  pure records

login :: Manager -> RateLimiter -> Config -> String -> String -> IO (Response LBS.ByteString)
login manager limiter config username password = do
  baseRequest <- parseRequest "https://www.space-track.org/ajaxauth/login"
  let request =
        urlEncodedBody
          [ ("identity", BS8.pack username)
          , ("password", BS8.pack password)
          ]
          baseRequest
            { requestHeaders = [("Accept", "application/json")]
            }
  response <- sendWithRetries manager limiter config (createCookieJar []) request
  let body = responseText response
  if "\"Login\":\"Failed\"" `T.isInfixOf` compact body || "\"Login\": \"Failed\"" `T.isInfixOf` body
    then throwIO AuthenticationFailed
    else pure response

getWithCookies :: Manager -> RateLimiter -> Config -> CookieJar -> String -> IO (Response LBS.ByteString)
getWithCookies manager limiter config jar url = do
  request <- parseRequest url
  sendWithRetries manager limiter config jar request {requestHeaders = [("Accept", "application/json")]}

logout :: Manager -> RateLimiter -> Config -> CookieJar -> IO (Response LBS.ByteString)
logout manager limiter config jar = do
  request <- parseRequest "https://www.space-track.org/ajaxauth/logout"
  sendWithRetries manager limiter config jar request

sendWithRetries ::
  Manager ->
  RateLimiter ->
  Config ->
  CookieJar ->
  Request ->
  IO (Response LBS.ByteString)
sendWithRetries manager limiter Config {..} jar request = go 0
 where
  go attempt = do
    acquire limiter
    result <- try (httpLbs requestWithCookies manager)
    case result of
      Left err -> retryOrFail attempt (NetworkRequestFailed (show (err :: SomeException)))
      Right response -> handleResponse attempt response

  requestWithCookies =
    request
      { responseTimeout = responseTimeoutMicro (cfgRequestTimeoutSeconds * 1000000)
      , cookieJar = Just jar
      }

  handleResponse attempt response =
    let code = statusCode (responseStatus response)
        body = responseText response
     in if code >= 200 && code < 300
          then pure response
          else
            if isRateLimit code body
              then retryAfter attempt 60 (TooManyRetries "Space-Track rate limit persisted")
              else
                if code `elem` transientStatusCodes
                  then retryAfter attempt (2 ^ min attempt (4 :: Int)) (TooManyRetries ("HTTP " <> show code <> " persisted"))
                  else throwIO (HttpRequestFailed code body)

  retryOrFail attempt err =
    if attempt >= cfgMaxRetries
      then throwIO err
      else retryAfter attempt (2 ^ min attempt (4 :: Int)) err

  retryAfter attempt seconds finalError =
    if attempt >= cfgMaxRetries
      then throwIO finalError
      else do
        threadDelay (seconds * 1000000)
        go (attempt + 1)

transientStatusCodes :: [Int]
transientStatusCodes = [502, 503, 504]

isRateLimit :: Int -> T.Text -> Bool
isRateLimit code body =
  code == 500 && "violated your query rate limit" `T.isInfixOf` T.toLower body

responseText :: Response LBS.ByteString -> T.Text
responseText =
  TE.decodeUtf8With TEE.lenientDecode . LBS.toStrict . responseBody

compact :: T.Text -> T.Text
compact = T.filter (not . (`elem` [' ', '\n', '\r', '\t']))
