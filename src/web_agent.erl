-module(web_agent).
-export([start/0, login/3, is_login/1, enter_room/2, play_vs_robot/3, play_vs_human/1, set_move/2, get_state/1, show/1]).

-record(state,  {username = none,
				 password = none,
				 room = none,
				 web_player = none,
				 player_client = none,
				 opponent_player = none}).

%% APIs.

start() ->
	P = spawn(fun() -> init() end),
	{ok, P}.

login(Pid, UserName, Password) ->
	call(Pid, {login, UserName, Password}).	

is_login(Pid) ->
	call(Pid, is_login).	

enter_room(Pid, RoomID) ->
	call(Pid, {enter_room, RoomID}).

play_vs_robot(Pid, RobotName, RobotType) ->
	call(Pid, {play_vs_robot, RobotName, RobotType}).

play_vs_human(Pid) ->
	call(Pid, play_vs_human).

set_move(Pid, Move) ->
	call(Pid, {set_move, Move}).

get_state(Pid) ->
	call(Pid, get_state).

show(Pid) ->
	call(Pid, show).

%%
init() ->
	loop(#state{}).

loop(State) ->
	receive
		{call, Ref, From, Msg} ->
			case handle_call(Msg, State) of
				{reply, Reply, NewState} ->
					From ! {Ref, Reply},
					loop(NewState);
				stop ->
					From ! {Ref, stop},
					stop
			end
	    after 180 * 1000 ->    %% keep state for 60 secs only
	        exit(time_out)			
	end.


call(Pid, Msg) ->
	Ref = make_ref(),
	Pid ! {call, Ref, self(), Msg},
	receive
		{Ref, Reply} ->
			Reply
	end.

handle_call(show, State) ->
	io:format("web_agent ~p state ~p~n", [self(), State]),
	{reply, ok, State};

handle_call({login, UserName, Password}, State=#state{username = none}) ->
	case game_auth:login(UserName, Password) of
			ok ->				
				{reply, ok, State#state{username = UserName, password = Password}};	
			Reaseon ->
				{reply, Reaseon, State}
	end;	

handle_call({login, UserName, _Password}, State=#state{username = LoginedName}) ->
	Reason = io_lib:format("user ~p already login, try login username ~p", [LoginedName, UserName]),
	io:format("~p~n", [Reason]),
	{reply, Reason, State};

handle_call(is_login, State=#state{username = none}) ->
	{reply, false, State};	

handle_call(is_login, State) ->
	{reply, true, State};	

handle_call({enter_room, RoomID}, State) ->
	{reply, ok, State#state{room = RoomID}};

handle_call(get_state, State=#state{web_player = WebPlayerPid}) ->
    {IsUpdateMove, Move, LegalMovesJsonList} = case webplayer:is_move(WebPlayerPid) of
		    	{ok, true} ->

		    		{ok, OpponentMove} = webplayer:get_opponent_move(WebPlayerPid),
		    		MoveJson = case OpponentMove of
		    			none -> "";
		    			{R, C, R1, C1} ->
							io:format("Opponent Move ~p~n", [OpponentMove]),		
		    				json2:obj_from_list([{"R", R}, {"C", C}, {"r", R1}, {"c", C1}])
		    		end,
					{ok, LegalMoves} = webplayer:get_legal_move(WebPlayerPid),
						LegalMovesJson = [ json2:obj_from_list([{"R", R}, {"C", C}, {"r", R1}, {"c", C1}]) || {R, C, R1, C1} <- LegalMoves ],
		    		{true, MoveJson, LegalMovesJson};
		    	_ -> 
		    		{false, [], []}
		   end,
	StateJson = json2:obj_from_list([{"is_update_move", IsUpdateMove},
									 {"move", Move},
									 {"legal_moves", {array, LegalMovesJsonList}}]),
	{reply, StateJson, State};
handle_call({set_move, Move}, State=#state{web_player = WebPlayerPid}) ->
	webplayer:set_move(WebPlayerPid, Move),	
	{reply, ok, State};

handle_call(play_vs_human, State=#state{username = UserName, password = Password, room = RoomID, 
		web_player = none, player_client = none}) ->
	{ok, Pid} = player_client:start(UserName, webplayer, board, "127.0.0.1", 8011),
	WebPlayerPid = player_client:get_player(Pid),
	player_client:login(Pid, Password),
	player_client:enter_room(Pid, RoomID),
	{reply, ok, State#state{player_client = Pid, web_player = WebPlayerPid}};

handle_call(play_vs_human, State=#state{player_client = PlayerClientPid, room = RoomID}) ->
	player_client:enter_room(PlayerClientPid, RoomID),
	{reply, ok, State};

handle_call({play_vs_robot, RobotName, RobotType}, State=#state{username = UserName, password = Password, room = Room, 
		web_player = none, player_client = none, opponent_player = none}) ->
	RoomID = get_room_id(Room),
	{ok, Pid} = player_client:start(UserName, webplayer, board, "127.0.0.1", 8011),
	WebPlayerPid = player_client:get_player(Pid),
	player_client:login(Pid, Password),	
	{ok, OpponentPid} = player_client:start(RobotName, RobotType, board, "127.0.0.1", 8011),	
	player_client:login(OpponentPid, ""),	
	player_client:enter_room(Pid, RoomID),
	player_client:enter_room(OpponentPid, RoomID),

	{reply, ok, State#state{room = RoomID, player_client = Pid, web_player = WebPlayerPid, opponent_player = OpponentPid}};

handle_call({play_vs_robot, _RobotName, _RobotType}, State=#state{player_client = PlayerClientPid, opponent_player = OpponentPid, room = RoomID}) ->
	player_client:enter_room(PlayerClientPid, RoomID),
	player_client:enter_room(OpponentPid, RoomID),
	{reply, ok, State}.

get_room_id(none) ->
	{ok, RoomID} = roommgr:get_empty_room(),
	RoomID;
get_room_id(RoomID) ->
	RoomID.

