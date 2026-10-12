-- Zen free models only (cost recorded as integer 0). Expected for October 2026: 0.00 USD, and the dashboard prices nothing.
CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
INSERT INTO session (id, directory) VALUES ('ses_1', '/work/alpha');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('zen_free_1', 'ses_1', 1791194400000, 1791194400000, '{"role":"assistant","providerID":"opencode","modelID":"big-pickle","cost":0,"tokens":{"total":0,"input":100,"output":50,"reasoning":7,"cache":{"read":1000,"write":20}},"time":{"created":1791194400000},"path":{"cwd":"/work/alpha","root":"/work/alpha"}}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('zen_free_2', 'ses_1', 1791547200000, 1791547200000, '{"role":"assistant","providerID":"opencode","modelID":"big-pickle","cost":0,"tokens":{"total":0,"input":100,"output":50,"reasoning":7,"cache":{"read":1000,"write":20}},"time":{"created":1791547200000},"path":{"cwd":"/work/alpha","root":"/work/alpha"}}');
