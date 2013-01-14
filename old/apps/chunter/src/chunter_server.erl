%%%-------------------------------------------------------------------
%%% @author Heinz N. Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz N. Gies
%%% @doc
%%%
%%% @end
%%% Created :  1 May 2012 by Heinz N. Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_server).

-behaviour(gen_server).

%% API
-export([start_link/0, 
	 list/0, 
	 get/1, 
	 start/1,
	 start/2,
	 stop/1,
	 reboot/1,
	 delete/1,
	 create/4,
	 get_vm/1, 
	 get_vm_pid/1, 
	 set_total_mem/1,
	 set_provisioned_mem/1,
	 provision_memory/1,
	 unprovision_memory/1,
	 connect/0,
	 create_vm/6,
	 disconnect/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(CPU_CAP_MULTIPLYER, 8).

-define(SERVER, ?MODULE). 

-record(state, {name, 
		port, 
		connected = false,
		datasets = [],
		capabilities = [],
		total_memory = 0, 
		provisioned_memory = 0}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

get(UUID) ->
    gen_server:call(?SERVER, {machines, get, UUID}).

start(UUID) ->
    gen_server:cast(?SERVER, {machines, start, UUID}).

start(UUID, Image) ->
    gen_server:cast(?SERVER, {machines, start, UUID, Image}).

stop(UUID) ->
    gen_server:cast(?SERVER, {machines, stop, UUID}).

reboot(UUID) ->
    gen_server:cast(?SERVER, {machines, reboot, UUID}).

delete(UUID) ->
    gen_server:cast(?SERVER, {machines, delete, UUID}).

create(UUID, PSpec, DSpec, OSpec) ->
    gen_server:cast(?SERVER, {machines, create, UUID, PSpec, DSpec, OSpec}).

set_total_mem(M) ->
    gen_server:cast(?SERVER, {set_total_mem, M}).

set_provisioned_mem(M) ->
    gen_server:cast(?SERVER, {set_provisioned_mem, M}).

provision_memory(M) ->
    gen_server:cast(?SERVER, {prov_mem, M}).

unprovision_memory(M) ->
    gen_server:cast(?SERVER, {unprov_mem, M}).

connect() ->
    gen_server:cast(?SERVER, connect).

disconnect() ->
    gen_server:cast(?SERVER, disconnect).

list() ->
    gen_server:call(?SERVER, {machines, list}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    lager:info([{fifi_component, chunter}],
	       "chunter:init.", []),
    % We subscribe to sniffle register channel - that way we can reregister to dead sniffle processes.
    [Host|_] = re:split(os:cmd("uname -n"), "\n"),
    mdns_client_lib_connection_event:add_handler(chunter_connect_event),
    libsniffle:hypervisor_register(Host, Host, 4200),
    lager:info([{fifi_component, chunter}],
	       "chunter:init - Host: ~s", [Host]),	
    {_, DS} = list_datasets([]),
    Capabilities = case os:cmd("ls /dev/kvm") of
		       "/dev/kvm\n" ->
			   [<<"zone">>, <<"kvm">>];
		       _ ->
			   [<<"zone">>]
		   end,
    {ok, #state{
       name = Host,
       datasets = DS,
       capabilities = Capabilities
      }}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({machines, list}, _From,  #state{name=Name} = State) ->
%    statsderl:increment([Name, ".call.machines.list"], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:list.", []),
    VMS = list_vms(Name),
    {reply, {ok, VMS}, State};

handle_call({machines, get, UUID}, _From, #state{name = _Name} =  State) ->
%    statsderl:increment([Name, ".call.machines.get.", UUID], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:get - UUID: ~s.", [UUID]),
    Pid = get_vm_pid(UUID),
    {ok, Reply} = chunter_vm:get(Pid),
    {reply, {ok, Reply}, State};

handle_call({call, Auth, {info, memory}}, _From, #state{name = Name,
							total_memory = T, 
							provisioned_memory = P} = State) ->
%    statsderl:increment([Name, ".call.info.memory"], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "hypervisor:info.memory.", []),
    {reply, {ok, {P, T}}, State};

% TODO
handle_call({call, Auth, {machines, info, UUID}}, _From, #state{name = Name} = State) ->
%    statsderl:increment([Name, ".call.machines.info.", UUID], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:info - UUID: ~s.", [UUID]),
    Pid = get_vm_pid(UUID),
    {ok, Reply} = chunter_vm:info(Pid),
    {reply, {ok, Reply}, State};

handle_call({call, Auth, {datasets, list}}, _From, #state{datasets=Ds, name=_Name} = State) ->
%    statsderl:increment([Name, ".call.datasets.list"], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "datasets:list", []),
    {Reply, Ds1} = list_datasets(Ds), 
    {reply, {ok, Reply}, State#state{datasets=Ds1}};

handle_call({call, Auth, {datasets, get, UUID}}, _From, #state{datasets=Ds, name=_Name} = State) ->
%    statsderl:increment([Name, ".call.datasets.get.", UUID], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "datasets:get - UUID: ~s.", [UUID]),
    {Reply, Ds1} = get_dataset(UUID, Ds), 
    {reply, {ok, Reply}, State#state{datasets=Ds1}};

handle_call({call, _Auth, Call}, _From, #state{name = _Name} = State) ->
%    statsderl:increment([Name, ".call.unknown"], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "unsupported call - ~p", [Call]),
    Reply = {error, {unsupported, Call}},
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknwon}, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast(connect,  #state{name = Host,
			     datasets = Datasets,
			     capabilities = Caps} = State) ->
%    {ok, Host} = libsnarl:option_get(system, statsd, hostname),
%    application:set_env(statsderl, hostname, Host),
    {TotalMem, _} = string:to_integer(os:cmd("/usr/sbin/prtconf | grep Memor | awk '{print $3}'")),
    Networks = re:split(os:cmd("cat /usbkey/config  | grep '_nic=' | sed 's/_nic.*$//'"), "\n"),
    Networks1 = lists:delete(<<>>, Networks),
    VMS = list_vms(Host),
    publish_datasets(Datasets),
    list_datasets(Datasets),
    ProvMem = round(lists:foldl(fun (VM, Mem) ->
				  {max_physical_memory, M} = lists:keyfind(max_physical_memory, 1, VM),
				  Mem + M
			  end, 0, VMS) / (1024*1024)),
    
%    statsderl:gauge([Name, ".hypervisor.memory.total"], TotalMem, 1),
%    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], ProvMem, 1),
    
%    statsderl:increment([Name, ".net.join"], 1, 1.0),
%    libsniffle:join_client_channel(),
    libsniffle:hypervisor_register(Host, Host, 4200),
    libsniffle:hypervisor_resource_set(Host, [{<<"networks">>, Networks1},
					      {<<"free-memory">>, TotalMem - ProvMem},
					      {<<"provisioned-memory">>, ProvMem},
					      {<<"total-memory">>, TotalMem},
					      {<<"virtualisation">>, Caps}]),
    
    {noreply, State#state{
		total_memory = TotalMem,
		provisioned_memory = ProvMem,
		connected = true
	       }};

handle_cast(disconnect,  State) ->
    {noreply, State#state{connected = false}};

handle_cast({set_total_mem, M}, State = #state{provisioned_memory = P,
					       name = Name}) ->
    libsniffle:hypervisor_resource_set(Name, [{<<"free-memory">>, M - P},
					      {<<"total-memory">>, M}]),
%    statsderl:gauge([Name, ".hypervisor.memory.total"], M, 1),
    {noreply, State#state{total_memory= M}};


handle_cast({set_provisioned_mem, M}, State = #state{name = Name,
						     provisioned_memory = P,
						     total_memory = T}) ->
    MinMB = round(M / (1024*1024)),
    Diff = round(P - MinMB),
    libsniffle:hypervisor_resource_set(Name, [{<<"free-memory">>, T - MinMB},
					      {<<"provisioned-memory">>, MinMB}]),
%    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], MinMB, 1),
    lager:info([{fifi_component, chunter}],
	       "memory:provision - Privisioned: ~p(~p), Total: ~p, Change: ~p .", [MinMB, M, T, Diff]),    
    {noreply, State#state{provisioned_memory = MinMB}};


handle_cast({prov_mem, M}, State = #state{name = Name,
					  provisioned_memory = P,
					  total_memory = T}) ->
    MinMB = round(M / (1024*1024)),
    Res = round(MinMB + P),
    libsniffle:hypervisor_resource_set(Name, [{<<"free-memory">>, T - Res},
					      {<<"provisioned-memory">>, Res}]),
%    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], Res, 1),
    lager:info([{fifi_component, chunter}],
	       "memory:provision - Privisioned: ~p(~p), Total: ~p, Change: +~p.", [Res, M, T, MinMB]),    
    {noreply, State#state{provisioned_memory = Res}};

handle_cast({unprov_mem, M}, State = #state{name = Name,
					    provisioned_memory = P, 
					    total_memory = T}) ->
    MinMB = round(M / (1024*1024)),
    Res = round(P - MinMB),
    libsniffle:hypervisor_resource_set(Name, [{<<"free-memory">>, T - Res},
					      {<<"provisioned-memory">>, Res}]),
%    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], Res, 1),
    lager:info([{fifi_component, chunter}],
	       "memory:unprovision - Unprivisioned: ~p(~p) , Total: ~p, Change: -~p.", [Res, M, T, MinMB]),
    {noreply, State#state{provisioned_memory = Res}};

handle_cast({machines, create, UUID, PSpec, DSpec, OSpec},
	    #state{datasets=Ds, name=Name} = State) ->
    spawn(chunter_server, create_vm, [UUID, PSpec, DSpec, OSpec, Ds, Name]),
    {noreply, State};


handle_cast({machines, delete, UUID}, #state{name = _Name} = State) ->
%    statsderl:increment([Name, ".cast.machines.delete"], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:delete - UUID: ~s.", [UUID]),
    VM = get_vm(UUID),
    case proplists:get_value(nics, VM) of
	undefined ->
	    [];
	Nics ->
	    [try
		 Net = proplists:get_value(<<"nic_tag">>, Nic),
		 IP = proplists:get_value(<<"ip">>, Nic),
		 libsniffle:iprange_release(Net, IP),
		 ok
	     catch 
		 _:_ ->
		     ok
	     end
	     || Nic <- Nics]
    end,
%    case libsnarl:group_get(system, <<"vm_", UUID/binary, "_owner">>) of
%	{ok, GUUID} ->
%	    libsnarl:group_delete(system, GUUID);
%	_ -> 
%	    ok
%   end,
    {max_physical_memory, Mem} = lists:keyfind(max_physical_memory, 1, VM),
%	    libsnarl:msg(Auth, success, <<"VM '", UUID/binary,"' is being deleted.">>),
    spawn(chunter_vmadm, delete, [UUID, Mem]),
    {noreply, State};

handle_cast({machines, start, UUID}, #state{name = _Name} = State) ->
    lager:info([{fifi_component, chunter}],
	       "machines:start - UUID: ~s.", [UUID]),
    spawn(chunter_vmadm, start, [UUID]),
    {noreply, State};

handle_cast({machines, start, UUID, Image}, #state{name = _Name} =State) ->
%    statsderl:increment([Name, ".cast.machines.start_image.", UUID], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:start - UUID: ~s, Image: ~s.", [UUID, Image]),
    spawn(chunter_vmadm, start, [UUID, Image]),
    {noreply, State};


handle_cast({machines, stop, UUID}, #state{name = _Name} = State) ->
%    statsderl:increment([Name, ".cast.machines.stop.", UUID], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:stop - UUID: ~s.", [UUID]),
    spawn(chunter_vmadm, stop, [UUID]),
    {noreply, State};

handle_cast({machines, reboot, UUID}, #state{name = _Name} =State) ->
%    statsderl:increment([Name, ".cast.machines.reboot.", UUID], 1, 1.0),
    lager:info([{fifi_component, chunter}],
	       "machines:reboot - UUID: ~s.", [UUID]),
    spawn(chunter_vmadm, reboot, [UUID]),
    {noreply, State};


handle_cast(Msg, #state{name = _Name} = State) ->
    lager:warning("Unknwn cast: ~p", Msg),
%    statsderl:increment([Name, ".cast.unknown"], 1, 1.0),
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


get_vm(ZUUID) ->
    [Hypervisor|_] = re:split(os:cmd("uname -n"), "\n"),
    [VM] = [chunter_zoneparser:load([{hypervisor, Hypervisor}, {name,Name},{state, VMState},{zonepath, Path},{uuid, UUID},{type, Type}]) || 
	       [ID,Name,VMState,Path,UUID,Type,_IP,_SomeNumber] <- 
		   [ re:split(Line, ":") 
		     || Line <- re:split(os:cmd("/usr/sbin/zoneadm -u" ++ binary_to_list(ZUUID) ++ " list -p"), "\n")],
	       ID =/= <<"0">>],
    VM.

list_vms(Hypervisor) ->
    [chunter_zoneparser:load([{hypervisor, Hypervisor}, {name,Name},{state, VMState},{zonepath, Path},{uuid, UUID},{type, Type}]) || 
	[ID,Name,VMState,Path,UUID,Type,_IP,_SomeNumber] <- 
	    [ re:split(Line, ":") 
	      || Line <- re:split(os:cmd("/usr/sbin/zoneadm list -ip"), "\n")],
	ID =/= <<"0">>].

get_dataset(UUID, Ds) ->
    read_dsmanifest(filename:join(<<"/var/db/imgadm">>, <<UUID/binary, ".json">>), Ds).



publish_datasets(Datasets) ->
    lists:foreach(fun({_, JSON}) ->
			  publish_dataset(JSON)
		  end, Datasets).
			  
publish_dataset(JSON) ->
    ID = proplists:get_value(<<"uuid">>, JSON),
    libsniffle:dataset_create(ID),
    Type = case proplists:get_value(<<"os">>, JSON) of
	       <<"smartos">> ->
		   <<"zone">>;
	       _ ->
		   <<"kvm">>
	   end,
    libsniffle:dataset_attribute_set(
      ID, 
      [{<<"dataset">>, ID},
       {<<"type">>, Type},
       {<<"name">>, proplists:get_value(<<"name">>, JSON)},
       {<<"networks">>,
	proplists:get_value(<<"networks">>,
			    proplists:get_value(<<"requirements">>, JSON))}
      ]).

list_datasets(Datasets) ->
    filelib:fold_files("/var/db/imgadm", ".*json", false, 
		       fun ("/var/db/imgadm/imgcache.json", R) ->
			       R;
			   (F, {Fs, DsA}) ->
			       {match, [UUID]} = re:run(F, "/var/db/imgadm/(.*)\.json", 
							[{capture, all_but_first, binary}]),
			       {F1, DsA1} = read_dsmanifest(F, DsA),
			       {[F1| Fs], DsA1}
		       end, {[], Datasets}).
			       
read_dsmanifest(F, Ds) ->
    case proplists:get_value(F, Ds) of
	undefined ->
	    {ok, Data} = file:read_file(F),
	    JSON = jsx:json_to_term(Data),
	    ID = proplists:get_value(<<"uuid">>, JSON),
	    JSON1 = [{<<"id">>, ID}|JSON],
	    publish_dataset(JSON1),
	    {JSON1, [{F, JSON1}|Ds]};
	JSON -> 
	    {JSON, Ds}
    end.


get_vm_pid(UUID) ->
    try gproc:lookup_pid({n, l, {vm, UUID}}) of
	Pid ->
	    Pid
    catch
	_T:_E ->
	    {ok, Pid} = chunter_vm_sup:start_child(UUID),
	    Pid
    end.

install_image(DatasetUUID) ->
    case filelib:is_regular(filename:join(<<"/var/db/imgadm">>, <<DatasetUUID/binary, ".json">>)) of
	true ->
	    ok;
	false ->
%	    libsnarl:msg(Auth, <<"warning">>, <<"Dataset needs to be imported!">>),
	    os:cmd(binary_to_list(<<"/usr/sbin/imgadm import ", DatasetUUID/binary>>))
    end.

create_vm(UUID, PSpec, DSpec, OSpec, Ds, Hypervisor) ->
%    statsderl:increment([Name, ".call.machines.create"], 1, 1.0),
    {<<"dataset">>, DatasetUUID} = lists:keyfind(<<"dataset">>, 1, DSpec),
    install_image(DatasetUUID),
    {Dataset, _Ds} = get_dataset(DatasetUUID, Ds),
    VMData = chunter_spec:to_vmadm(PSpec, DSpec, [{<<"uuid">>, UUID} | OSpec]),
    chunter_vmadm:create(VMData).