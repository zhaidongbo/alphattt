-module(room).
-export([start/1]).
-export([enter/2, leave/2, play/2, show/1]).
-export([reset/1]).

-record(state, {board,
				status = waiting, % status = waiting ! playing
				current_player = none,
				players = [], % players = [{pid, nick_name, monitor_ref}]
				game_state,
				steps = []
				}).

%% APIs
start(Board) ->
	Pid = spawn(fun() -> init(Board) end),
	{ok, Pid}.

enter(Pid, {Player, NickName}) ->
	Pid ! {enter, Player, NickName}.

leave(Pid, Player) ->
	Pid ! {leave, Player}.

play(Pid, {Player, Move}) ->
	Pid ! {play, Player, Move}.

reset(Pid) ->
	Pid ! reset.

show(Pid) ->
	Pid ! show.	

init(Board) ->
	<<A:32, B:32, C:32>> = crypto:rand_bytes(12),
	random:seed({A, B, C}),
	loop(#state{board = Board}).	

select_player(Players) ->
	N = random:uniform(2),
	{Pid, NickName, _} = lists:nth(N, Players),
	{Pid, NickName}.	

loop(State = #state{status = waiting, board = Board, players = Players}) ->
	receive
		{enter, Pid, NickName} ->
			case Players of
				[] ->
					notify_user(Pid, greeting(NickName)),
					Ref = erlang:monitor(process, Pid),
					loop(State#state{players = [{Pid, NickName, Ref}]});
				[{Pid, _, _}] ->
					notify_user(Pid, greeting(NickName)),				
					loop(State);
				[{_Pid2, _, _}] ->
					notify_user(Pid, greeting(NickName)),
					Ref = erlang:monitor(process, Pid),
					NewPlayers = [{Pid, NickName, Ref} | Players],
					First = select_player(NewPlayers),
					GameState = Board:start(),
					self() ! begin_game,
					loop(State#state{status = playing,
									 game_state = GameState,
									 current_player = First,
									 players = NewPlayers})
			end;
		{leave, Pid} ->
			case lists:keyfind(Pid, 1, Players) of
				{Pid, _, Ref} ->
					NewPlayers = lists:keydelete(Pid, 1, Players),
					erlang:demonitor(Ref),
					loop(State#state{players=NewPlayers});
				false ->
					loop(State)
			end;
		show ->
			io:format("status=~p, players=~p~n", [State#state.status, Players]),
			loop(State);
		reset ->
			loop(State#state{status=waiting,
				 players=[],
				 current_player=none});			
		{'DOWN', _, process, Pid, Reason} ->
			io:format("~p down @waiting for: ~p~n", [Pid, Reason]),
			self() ! {leave, Pid},
			loop(State);
		Unexpected ->
			io:format("unexpected @waiting ~p~n", [Unexpected]),
			loop(State)
	end;
loop(State = #state{status = playing,
					current_player = {Current, CurrentNickName},
					players = Players,
					board = Board,
					game_state = GameState, 
					steps = Steps}) ->
	receive 
		{enter, _Pid, _NickName} ->
			loop(State);
		{leave, Pid} ->
			case lists:keyfind(Pid, 1, Players) of
				{Pid, _NickName, Ref} ->
					NewPlayers = [{_Pid2, _NickName2, _}]
							   = lists:keydelete(Pid, 1, Players),
					erlang:demonitor(Ref),
					loop(State#state{status=waiting,
									 current_player = none,
									 players = NewPlayers});
				_ ->
					loop(State)
			end;
		show ->
			io:format("status=~p, current_player=~p, players=~p~n", [State#state.status, CurrentNickName, Players]),
			loop(State);
		begin_game ->
			{Next, NextNickName} = next_player(Current, Players),
			update(Current, GameState),
			update(Next, GameState),
			play(Current),
			loop(State#state{steps = [{start, CurrentNickName, NextNickName}]});
		reset ->
			loop(State#state{status=waiting,
				 players=[],
				 current_player=none});
		{play, Current, Move} ->
			case Board:is_legal(GameState, Move) of
				false ->
					play(Current),
					loop(State);
				true ->
					GameState2 = Board:next_state(GameState, Move),
					NextPlayer = {Next, _} = next_player(Current, Players),
					update(Current, Move, GameState2),
					update(Next, Move, GameState2),
					NewSteps = Steps ++ [{move, integer_to_list(Board:current_player(GameState)), Move}],
					case Board:winner(GameState2) of
						on_going ->
							play(Next),
							loop(State#state{game_state = GameState2,
											 current_player = NextPlayer,
											 steps=NewSteps});
						draw ->
							store_data(NewSteps ++ [{finish, draw}]),
							loop(State#state{status = waiting,
											 players=[],
											 current_player=none,
											 steps=[]});
						_ ->
							[notify_user(Pid, congradulations(CurrentNickName)) || {Pid, _, _} <- Players],
							store_data(NewSteps ++ [{finish, winner, integer_to_list(Board:current_player(GameState))}]),
							loop(State#state{status=waiting,
											 players=[],
											 current_player=none,
											 steps=[]})
					end
			end;		
		{'DOWN', _, process, Pid, Reason} ->
			io:format("~p down @waiting for: ~p~n", [Pid, Reason]),
			self() ! {leave, Pid},
			loop(State);
		Unexpected ->
			io:format("unexpected @waiting ~p~n", [Unexpected]),
			loop(State)
	end.


next_player(Pid, [{Pid, _, _}, {Pid2, NickName, _}]) ->
	{Pid2, NickName};
next_player(Pid, [{Pid2, NickName, _}, {Pid, _, _}]) ->
	{Pid2, NickName}.

update(Pid, GameState) ->
	Pid ! {update, none, GameState}.
update(Pid, Move, GameState) ->
	Pid ! {update, Move, GameState}.
play(Pid) ->
	Pid ! play.

notify_user(Pid, Msg) ->
	Pid ! {notify, Msg}.	

greeting(NickName) ->
	"welcome " ++ NickName.

congradulations(NickName) ->
	NickName ++ " Wins!!!".

store_data(Steps) ->
	{ok, CurrentDir} = file:get_cwd(),
	make_dir(),
	{ok, LogFile} = file:open(make_filename(), [append]),	
	[store_data(Step, LogFile) || Step <- Steps],
	file:close(LogFile),
	file:set_cwd(CurrentDir).

store_data({start, CurrentNickName, NextNickName}, LogFile) ->	
	io:format(LogFile, "{\"begin\":[~p,~p]}~n", [CurrentNickName, NextNickName]);
store_data({move, Player, {R, C, R1, C1}}, LogFile) ->
	io:format(LogFile, "{~p:[~p,~p,~p,~p]}~n", [Player, R, C, R1, C1]);
store_data({finish, draw}, LogFile) ->	
	io:format(LogFile, "{~p:~p}~n", ["end", "draw"]);
store_data({finish, winner, Player}, LogFile) ->	
	io:format(LogFile, "{~p:~p}~n", ["end", Player]).

make_dir() ->
	DataDir = "play_data",
	file:make_dir(DataDir),
	file:set_cwd(DataDir),
	{Year, Month, Day} = date(),	 
	Dir = io_lib:format("~p_~p_~p", [Year, Month, Day]),
	file:make_dir(Dir),
	file:set_cwd(Dir).

make_filename() ->
	{MegaSecs, Secs, MicroSecs} = now(),
	io_lib:format("~p_~p_~p_~p.txt", [MegaSecs, Secs, MicroSecs, random:uniform(100)]).


