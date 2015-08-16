% this record for keep internal message routing rules
-record(msg_routes, {
		ets_name
	}).
-record(active_route, {
		topic,							% we can specify topic
		dest,							% subscriber
		dest_type
	}). 
