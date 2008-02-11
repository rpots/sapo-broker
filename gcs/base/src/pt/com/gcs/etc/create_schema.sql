CREATE TABLE IF NOT EXISTS Message (msg_id varchar(50), correlation_id varchar(50), destination varchar(255), priority int, mtimestamp bigint, expiration bigint, source_app varchar(100), content varchar, sequence_nr bigint, delivery_count int, local_only boolean DEFAULT false, PRIMARY KEY(msg_id, destination));
CREATE TABLE IF NOT EXISTS VirtualQueue (queue_name varchar(255), PRIMARY KEY(queue_name));