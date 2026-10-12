-- Zen pay-as-you-go with no spend this month: every Zen row is from September. Expected for October 2026: 0.00 USD.
CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
INSERT INTO session (id, directory) VALUES ('ses_1', '/work/alpha');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('zen_sep_1', 'ses_1', 1789466400000, 1789466400000, '{"role":"assistant","providerID":"opencode","modelID":"glm-5.2","cost":3.25,"tokens":{"total":0,"input":100,"output":50,"reasoning":7,"cache":{"read":1000,"write":20}},"time":{"created":1789466400000},"path":{"cwd":"/work/alpha","root":"/work/alpha"}}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('zen_sep_2', 'ses_1', 1790812799000, 1790812799000, '{"role":"assistant","providerID":"opencode","modelID":"glm-5.2","cost":1,"tokens":{"total":0,"input":100,"output":50,"reasoning":7,"cache":{"read":1000,"write":20}},"time":{"created":1790812799000},"path":{"cwd":"/work/alpha","root":"/work/alpha"}}');
