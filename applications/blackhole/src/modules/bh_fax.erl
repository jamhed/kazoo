%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2016, 2600Hz Inc
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Peter Defebvre
%%%   Roman Galeev
%%%-------------------------------------------------------------------
-module(bh_fax).

-export([handle_event/2
        ,handle_object_event/2
        ,subscribe/2
        ,unsubscribe/2
        ]).

-include("blackhole.hrl").

-spec handle_event(bh_context:context(), kz_json:object()) -> 'ok'.
handle_event(#bh_context{binding=Binding} = Context, EventJObj) ->
    kz_util:put_callid(EventJObj),
    'true' = kapi_fax:status_v(EventJObj),
    NormJObj = kz_json:normalize_jobj(kz_json:set_value(<<"Binding">>, Binding, EventJObj)),
    blackhole_data_emitter:emit(bh_context:websocket_pid(Context), event_name(EventJObj), NormJObj).

-spec handle_object_event(bh_context:context(), kz_json:object()) -> 'ok'.
handle_object_event(#bh_context{binding=Binding} = Context, EventJObj) ->
    kz_util:put_callid(EventJObj),
    %% TODO: check account id
    NormJObj = kz_json:normalize_jobj(kz_json:set_value(<<"Binding">>, Binding, EventJObj)),
    blackhole_data_emitter:emit(bh_context:websocket_pid(Context), event_name(EventJObj), NormJObj).

-spec event_name(kz_json:object()) -> ne_binary().
event_name(_JObj) -> <<"fax.status">>.

-spec subscribe(bh_context:context(), ne_binary()) -> {'ok', bh_context:context()}.
subscribe(Context, <<"fax.status.", FaxId/binary>> = Binding) ->
    blackhole_listener:add_binding('fax', fax_status_bind_options(bh_context:account_id(Context), FaxId)),
    blackhole_bindings:bind(Binding, ?MODULE, 'handle_event', Context),
    {'ok', Context};
%% listen to: doc_edited.faxes.fax.0f79141acb547d8e8e564925c414cc0e
subscribe(Context, <<"fax.object.", Action/binary>>) ->
    blackhole_bindings:bind(<<Action/binary,".faxes.fax.*">>, ?MODULE, 'handle_object_event', Context),
    blackhole_listener:add_binding('conf', fax_object_bind_options(Action)),
    {'ok', Context};
subscribe(Context, Binding) ->
    blackhole_util:send_error_message(Context, <<"unmatched binding">>, Binding),
    {'ok', Context}.

-spec unsubscribe(bh_context:context(), ne_binary()) -> {'ok', bh_context:context()}.
unsubscribe(Context, <<"fax.status.", FaxId/binary>> = Binding) ->
    blackhole_listener:remove_binding('fax', fax_status_bind_options(bh_context:account_id(Context), FaxId)),
    blackhole_bindings:unbind(Binding, ?MODULE, 'handle_event', Context),
    {'ok', Context};
unsubscribe(Context, <<"fax.object.", Action/binary>>) ->
    blackhole_bindings:bind(<<Action/binary,".faxes.fax.*">>, ?MODULE, 'handle_object_event', Context),
    blackhole_listener:add_binding('conf', fax_object_bind_options(Action)),
    {'ok', Context};
unsubscribe(Context, Binding) ->
    blackhole_util:send_error_message(Context, <<"unmatched binding">>, Binding),
    {'ok', Context}.

fax_status_bind_options(AccountId, FaxId) ->
    [{'restrict_to', ['status']}
    ,{'account_id', AccountId}
    ,{'fax_id', FaxId}
    ,'federate'
    ].

-spec fax_object_bind_options(ne_binary()) -> kz_json:object().
fax_object_bind_options(Action) ->
    [{'keys', [[{'action', Action}, {'db', <<"faxes">>}, {'doc_type', <<"fax">>}]]}
    ,'federate'
    ].
