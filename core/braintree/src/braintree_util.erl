%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2017, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(braintree_util).

-export([make_doc_xml/2]).
-export([bt_error_to_json/1]).
-export([bt_verification_to_json/1]).
-export([bt_api_error_to_json/1]).

-export([error_no_payment_token/0]).
-export([error_authentication/0]).
-export([error_authorization/0]).
-export([error_not_found/1]).
-export([error_upgrade_required/0]).
-export([error_server_error/0]).
-export([error_maintenance/0]).
-export([error_api/1]).
-export([error_io_fault/0]).
-export([error_min_amount/1]).
-export([error_max_amount/1]).

-include("bt.hrl").

%% from stdlib/src/unicode.erl
-type char_to_bin_res() :: binary() |
                           {'error', binary(), unicode:latin1_chardata() | unicode:chardata() | unicode:external_chardata()} |
                           {'incomplete', binary(), binary()}.
-export_type([char_to_bin_res/0]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec make_doc_xml(kz_proplist(), atom()) -> char_to_bin_res().
make_doc_xml(Props, Root) ->
    Xml = xmerl:export_simple([doc_xml_simple(Props, Root)], 'xmerl_xml'
                             ,[{'prolog', ?BT_XML_PROLOG}]
                             ),
    unicode:characters_to_binary(Xml).

doc_xml_simple(Props, Root) ->
    {Root, props_to_xml(Props, [])}.

props_to_xml([], Xml) ->
    Xml;
props_to_xml([{_, 'undefined'}|T], Xml) ->
    props_to_xml(T, Xml);
props_to_xml([{_, _, 'undefined'}|T], Xml) ->
    props_to_xml(T, Xml);
props_to_xml([{_, []}|T], Xml) ->
    props_to_xml(T, Xml);

props_to_xml([{K, [{_, _, _}|_]=V}|T], Xml) ->
    props_to_xml(T, [{K, props_to_xml(V, [])}|Xml]);
props_to_xml([{K, Attr, [{_, _}|_]=V}|T], Xml) ->
    props_to_xml(T, [{K, Attr, props_to_xml(V, [])}|Xml]);
props_to_xml([{K, Attr, [{_, _, _}|_]=V}|T], Xml) ->
    props_to_xml(T, [{K, Attr, props_to_xml(V, [])}|Xml]);
props_to_xml([{K, Attr, V}|T], Xml) when is_boolean(V) ->
    props_to_xml(T, [{K, [{'type', "boolean"}|Attr], [kz_term:to_list(V)]}|Xml]);
props_to_xml([{K, Attr, V}|T], Xml) ->
    props_to_xml(T, [{K, Attr, [kz_term:to_list(V)]}|Xml]);

props_to_xml([{K, [{_, _}|_]=V}|T], Xml) ->
    props_to_xml(T, [{K, props_to_xml(V, [])}|Xml]);
props_to_xml([{K, V}|T], Xml) when is_boolean(V) ->
    props_to_xml(T, [{K, [{'type', "boolean"}], [kz_term:to_list(V)]}|Xml]);
props_to_xml([{K, V}|T], Xml) ->
    props_to_xml(T, [{K, [kz_term:to_list(V)]}|Xml]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec bt_error_to_json(bt_error()) -> kz_json:object().
bt_error_to_json(BtError) ->
    Props = [{<<"code">>, BtError#bt_error.code}
            ,{<<"message">>, BtError#bt_error.message}
            ,{<<"attribute">>, BtError#bt_error.attribute}
            ],
    kz_json:from_list(props:filter_undefined(Props)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec bt_verification_to_json(bt_verification()) -> kz_json:object().
bt_verification_to_json(BtVerification) ->
    Props = [{<<"verification_status">>, BtVerification#bt_verification.verification_status}
            ,{<<"processor_response_code">>, BtVerification#bt_verification.processor_response_code}
            ,{<<"processor_response_text">>, BtVerification#bt_verification.processor_response_text}
            ,{<<"cvv_response_code">>, BtVerification#bt_verification.cvv_response_code}
            ,{<<"avs_response_code">>, BtVerification#bt_verification.avs_response_code}
            ,{<<"postal_response_code">>, BtVerification#bt_verification.postal_response_code}
            ,{<<"street_response_code">>, BtVerification#bt_verification.street_response_code}
            ,{<<"gateway_rejection_reason">>, BtVerification#bt_verification.gateway_rejection_reason}
            ],
    kz_json:from_list(props:filter_undefined(Props)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec bt_api_error_to_json(bt_api_error()) -> kz_json:object().
bt_api_error_to_json(BtApiError) ->
    Props = [{<<"errors">>, [bt_error_to_json(Error) || Error <- BtApiError#bt_api_error.errors]}
            ,{<<"verification">>, bt_verification_to_json(BtApiError#bt_api_error.verification)}
            ,{<<"message">>, BtApiError#bt_api_error.message}
            ],
    kz_json:from_list(props:filter_undefined(Props)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_no_payment_token() -> no_return().
error_no_payment_token() ->
    Error = <<"No credit card found">>,
    lager:debug("~s", [Error]),
    throw({'no_payment_token', kz_json:from_list([{<<"no_payment_token">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_authentication() -> no_return().
error_authentication() ->
    Error = <<"Failed to authenticate with the card processor">>,
    lager:debug("~s", [Error]),
    throw({'authentication', kz_json:from_list([{<<"authentication">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_authorization() -> no_return().
error_authorization() ->
    Error = <<"Failed to authorize with the card processor">>,
    lager:debug("~s", [Error]),
    throw({'authorization', kz_json:from_list([{<<"authorization">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_not_found(ne_binary()) -> no_return().
error_not_found(Object) ->
    Error = <<Object/binary, " not found">>,
    lager:debug("~s", [Error]),
    throw({'not_found', kz_json:from_list([{<<"not_found">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_upgrade_required() -> no_return().
error_upgrade_required() ->
    Error = <<"Card processor requires API library upgrade">>,
    lager:warning("~s", [Error]),
    throw({'upgrade_required', kz_json:from_list([{<<"upgrade_required">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_server_error() -> no_return().
error_server_error() ->
    Error = <<"Card processor server error">>,
    lager:debug("~s", [Error]),
    throw({'server_error', kz_json:from_list([{<<"server_error">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_maintenance() -> no_return().
error_maintenance() ->
    Error = <<"Card processor currently down for maintenance">>,
    lager:debug("~s", [Error]),
    throw({'maintenance', kz_json:from_list([{<<"maintenance">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_api(bt_api_error()) -> no_return().
error_api(ApiError) ->
    JObj = bt_api_error_to_json(ApiError),
    lager:debug("~s", [kz_json:encode(JObj)]),
    throw({'api_error', kz_json:from_list([{<<"api_error">>, JObj}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_io_fault() -> no_return().
error_io_fault() ->
    Error = <<"Unable to establish communication with card processor">>,
    lager:debug("~s", [Error]),
    throw({'io_fault', kz_json:from_list([{<<"io_fault">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_min_amount(number() | ne_binary()) -> no_return().
error_min_amount(Amount) ->
    Error = <<"Unable to process a transaction for less than $", (kz_term:to_binary(Amount))/binary>>,
    lager:debug("~s", [Error]),
              throw({'min_amount', kz_json:from_list([{<<"min_amount">>, Error}])}).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec error_max_amount(number() | ne_binary()) -> no_return().
error_max_amount(Amount) ->
    Error = <<"Unable to process a transaction for more than $", (kz_term:to_binary(Amount))/binary>>,
    lager:debug("~s", [Error]),
              throw({'max_amount', kz_json:from_list([{<<"max_amount">>, Error}])}).
