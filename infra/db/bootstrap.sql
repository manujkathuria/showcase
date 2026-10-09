\set ON_ERROR_STOP on
CREATE ROLE streaming_owner NOLOGIN;
CREATE ROLE streaming_app LOGIN PASSWORD 'CHANGE_ME_BEFORE_RUNNING' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE DATABASE intraday_streaming OWNER streaming_owner;
\connect intraday_streaming
REVOKE ALL ON DATABASE intraday_streaming FROM PUBLIC;
GRANT CONNECT ON DATABASE intraday_streaming TO streaming_app;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA feed AUTHORIZATION streaming_owner;
CREATE SCHEMA extensions AUTHORIZATION streaming_owner;
CREATE EXTENSION timescaledb WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA feed TO streaming_app;
ALTER DEFAULT PRIVILEGES FOR ROLE streaming_owner IN SCHEMA feed GRANT SELECT ON TABLES TO streaming_app;
ALTER ROLE streaming_app IN DATABASE intraday_streaming SET search_path = pg_catalog, feed;
