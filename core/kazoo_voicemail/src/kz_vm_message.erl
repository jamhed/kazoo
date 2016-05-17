%%%-------------------------------------------------------------------
%%% @copyright (C) 2016, 2600Hz
%%% @doc
%%% Voice mail message
%%% @end
%%% @contributors
%%%   Hesaam Farhang
%%%-------------------------------------------------------------------
-module(kz_vm_message).

-export([new_message/5
         ,message_doc/2
         ,message/2, messages/2, fetch_vmbox_messages/2
         ,count/2, count_per_folder/2, count_modb_messages/3
         ,count_by_owner/2
         ,set_folder/3, update_folder/3

         ,media_url/2

         ,load_vmbox/2, load_vmbox/3, vmbox_summary/1
         ,update_message_doc/2, update_message_doc/3, update_multi_messages/3
         ,find_message_differences/3

         ,get_db/1, get_db/2
         ,get_range_view/2

         ,migrate/0, migrate/1, migrate/2
         ,cleanup_heard_voicemail/1
        ]).

-include("kz_voicemail.hrl").
-include_lib("kazoo/src/kz_json.hrl").

-define(APP_NAME, <<"callflow">>).
-define(APP_VERSION, <<"4.0.0">> ).
-define(CF_CONFIG_CAT, <<"callflow">>).
-define(KEY_VOICEMAIL, <<"voicemail">>).
-define(KEY_RETENTION_DURATION, <<"message_retention_duration">>).

-define(MODB_LISTING_BY_MAILBOX, <<"mailbox_messages/listing_by_mailbox">>).
-define(MODB_COUNT_VIEW, <<"mailbox_messages/count_per_folder">>).
-define(COUNT_BY_VMBOX, <<"mailbox_messages/count_by_vmbox">>).
-define(BOX_MESSAGES_CB_LIST, <<"vmboxes/crossbar_listing">>).

-define(RETENTION_DURATION
        ,kapps_config:get_integer(?CF_CONFIG_CAT
                           ,[?KEY_VOICEMAIL, ?KEY_RETENTION_DURATION]
                           ,93 %% 93 days(3 months)
                          )
       ).

-define(RETENTION_DAYS(Duration)
        ,?SECONDS_IN_DAY * Duration + ?SECONDS_IN_HOUR
       ).

-type db_ret() :: 'ok' | {'ok', kz_json:object() | kz_json:objects()} | {'error', any()}.

%%--------------------------------------------------------------------
%% @public
%% @doc Generate database name based on DocId
%% @end
%%--------------------------------------------------------------------
-spec get_db(ne_binary()) -> ne_binary().
get_db(AccountId) ->
    kz_util:format_account_id(AccountId, 'encoded').

-spec get_db(ne_binary(), kazoo_data:docid() | kz_json:object()) -> ne_binary().
get_db(AccountId, {_, ?MATCH_MODB_PREFIX(Year, Month, _)}) ->
    get_db(AccountId, Year, Month);
get_db(AccountId, ?MATCH_MODB_PREFIX(Year, Month, _)) ->
    get_db(AccountId, Year, Month);
get_db(AccountId, ?JSON_WRAPPER(_)=Doc) ->
    get_db(AccountId, kz_doc:id(Doc));
get_db(AccountId, _DocId) ->
    get_db(AccountId).

-spec get_db(ne_binary(), ne_binary(), ne_binary()) -> ne_binary().
get_db(AccountId, Year, Month) ->
    kazoo_modb:get_modb(AccountId, kz_util:to_integer(Year), kz_util:to_integer(Month)).

%%--------------------------------------------------------------------
%% @public
%% @doc recieve a new voicemail message and store it
%% expected options:
%%  [{<<"Attachment-Name">>, AttachmentName}
%%    ,{<<"Box-Id">>, BoxId}
%%    ,{<<"OwnerId">>, OwnerId}
%%    ,{<<"Length">>, Length}
%%    ,{<<"Transcribe-Voicemail">>, MaybeTranscribe}
%%    ,{<<"After-Notify-Action">>, Action}
%%  ]
%% @end
%%--------------------------------------------------------------------
-spec new_message(ne_binary(), ne_binary(), ne_binary(), kapps_call:call(), kz_proplist()) -> any().
new_message(AttachmentName, BoxNum, Timezone, Call, Props) ->
    BoxId = props:get_value(<<"Box-Id">>, Props),
    Length = props:get_value(<<"Length">>, Props),

    lager:debug("saving new ~bms voicemail media and metadata", [Length]),

    {MediaId, MediaUrl} = create_message_doc(AttachmentName, BoxNum, Call, Timezone, Props),

    Msg = io_lib:format("failed to store voicemail media ~s in voicemail box ~s of account ~s"
                        ,[MediaId, BoxId, kapps_call:account_id(Call)]
                       ),
    Funs = [{fun kapps_call:kvs_store/3, 'mailbox_id', BoxId}
            ,{fun kapps_call:kvs_store/3, 'attachment_name', AttachmentName}
            ,{fun kapps_call:kvs_store/3, 'media_id', MediaId}
            ,{fun kapps_call:kvs_store/3, 'media_length', Length}
           ],

    lager:debug("storing voicemail media recording ~s in doc ~s", [AttachmentName, MediaId]),
    case store_recording(AttachmentName, MediaUrl, kapps_call:exec(Funs, Call)) of
        'ok' ->
            _ = notify_and_save_meta(Call, MediaId, Length, Props),
            'ok';
        {'error', Call1} ->
            lager:error(Msg),
            {'error', Call1, Msg}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_message_doc(ne_binary(), ne_binary(), kapps_call:call(), ne_binary(), kz_proplist()) ->
                                {ne_binary(), ne_binary()}.
create_message_doc(AttachmentName, BoxNum, Call, Timezone, Props) ->
    {Year, Month, _} = erlang:date(),
    Db = kazoo_modb:get_modb(kapps_call:account_id(Call), Year, Month),

    MediaId = <<(kz_util:to_binary(Year))/binary
                ,(kz_util:pad_month(Month))/binary
                ,"-"
                ,(kz_util:rand_hex_binary(16))/binary
              >>,
    Doc = kzd_box_message:new(Db, MediaId, AttachmentName, BoxNum, Timezone, Props),
    {'ok', JObj} = kz_datamgr:save_doc(Db, Doc),
    MediaUrl = kz_media_url:store(JObj, AttachmentName),

    {MediaId, MediaUrl}.

-spec store_recording(ne_binary(), ne_binary(), kapps_call:call()) ->
                                 'ok' |
                                 {'error', kapps_call:call()}.
store_recording(AttachmentName, Url, Call) ->
    lager:debug("storing recording ~s at ~s", [AttachmentName, Url]),
    case kapps_call_command:store_file(<<"/tmp/", AttachmentName/binary>>, Url, Call) of
        'ok' -> 'ok';
        {'error', _} -> {'error', Call}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec notify_and_save_meta(kapps_call:call(), ne_binary(), integer(), kz_proplist()) -> 'ok' | db_ret().
notify_and_save_meta(Call, MediaId, Length, Props) ->
    BoxId = props:get_value(<<"Box-Id">>, Props),
    NotifyAction = props:get_atom_value(<<"After-Notify-Action">>, Props),

    case publish_voicemail_saved_notify(MediaId, BoxId, Call, Length, Props) of
        {'ok', JObjs} ->
            JObj = get_completed_msg(JObjs),
            maybe_save_meta(Length, NotifyAction, Call, MediaId, JObj, BoxId);
        {'timeout', JObjs} ->
            case get_completed_msg(JObjs) of
                ?EMPTY_JSON_OBJECT ->
                    lager:info("timed out waiting for voicemail new notification resp"),
                    save_meta(Length, NotifyAction, Call, MediaId, BoxId);
                JObj ->
                    maybe_save_meta(Length, NotifyAction, Call, MediaId, JObj, BoxId)
            end;
        {'error', _E} ->
            lager:debug("voicemail new notification error: ~p", [_E]),
            save_meta(Length, NotifyAction, Call, MediaId, BoxId)
    end.

-spec get_completed_msg(kz_json:objects()) -> kz_json:object().
get_completed_msg(JObjs) ->
    get_completed_msg(JObjs, kz_json:new()).

-spec get_completed_msg(kz_json:objects(), kz_json:object()) -> kz_json:object().
get_completed_msg([], Acc) -> Acc;
get_completed_msg([JObj|JObjs], Acc) ->
    case kz_json:get_value(<<"Status">>, JObj) of
        <<"completed">> -> get_completed_msg([], JObj);
        _ -> get_completed_msg(JObjs, Acc)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_save_meta(pos_integer(), atom(), kapps_call:call(), ne_binary(), kz_json:object(), ne_binary()) -> 'ok' | db_ret().
maybe_save_meta(Length, 'nothing', Call, MediaId, _UpdateJObj, BoxId) ->
    save_meta(Length, 'nothing', Call, MediaId, BoxId);

maybe_save_meta(Length, Action, Call, MediaId, UpdateJObj, BoxId) ->
    case kz_json:get_value(<<"Status">>, UpdateJObj) of
        <<"completed">> ->
            save_meta(Length, Action, Call, MediaId, BoxId);
        <<"failed">> ->
            lager:debug("attachment failed to send out via notification: ~s", [kz_json:get_value(<<"Failure-Message">>, UpdateJObj)]),
            save_meta(Length, Action, Call, MediaId, BoxId)
    end.

-spec save_meta(pos_integer(), atom(), kapps_call:call(), ne_binary(), ne_binary()) -> 'ok' | db_ret().
save_meta(Length, Action, Call, MediaId, BoxId) ->
    AccountId = kapps_call:account_id(Call),
    CIDNumber = get_caller_id_number(Call),
    CIDName = get_caller_id_name(Call),
    Timestamp = new_timestamp(),

    Metadata = kzd_box_message:build_metadata_object(Length, Call, MediaId, CIDNumber, CIDName, Timestamp),

    case Action of
        'delete' ->
            lager:debug("attachment was sent out via notification, deleteing media file"),
            Fun = [fun(JObj) ->
                       apply_folder(?VM_FOLDER_DELETED, JObj)
                   end
                  ],
            {'ok', _} = save_metadata(Metadata, AccountId, MediaId, Fun);
        'save' ->
            lager:debug("attachment was sent out via notification, saving media file"),
            Fun = [fun(JObj) ->
                       apply_folder(?VM_FOLDER_SAVED, JObj)
                   end
                  ],
            {'ok', _} = save_metadata(Metadata, AccountId, MediaId, Fun);
        'nothing' ->
            {'ok', _} = save_metadata(Metadata, AccountId, MediaId, []),
            lager:debug("stored voicemail metadata for ~s", [MediaId]),
            publish_voicemail_saved(Length, BoxId, Call, MediaId, Timestamp)
    end.

-spec save_metadata(kz_json:object(), ne_binary(), ne_binary(), update_funs()) -> db_ret().
save_metadata(NewMessage, AccountId, MessageId, Funs) ->
    UpdateFuns = [fun(JObj) ->
                      kzd_box_message:set_metadata(NewMessage, JObj)
                  end
                  | Funs
                 ],

    case retry_conflict(update_message_doc(AccountId, MessageId, UpdateFuns)) of
        {'ok', _}=OK -> OK;
        {'error', R}=E ->
            lager:info("error while storing voicemail metadata: ~p", [R]),
            E
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc fetch whole message doc from db. It will take care if the message
%% message is stil in accountdb, it will merge metadata from vmbox
%% @end
%%--------------------------------------------------------------------
-spec message_doc(ne_binary(), kazoo_data:docid()) -> db_ret().
message_doc(AccountId, {_, ?MATCH_MODB_PREFIX(Year, Month, _)}=DocId) ->
    open_modb_doc(AccountId, DocId, Year, Month);
message_doc(AccountId, ?MATCH_MODB_PREFIX(Year, Month, _)=DocId) ->
    open_modb_doc(AccountId, DocId, Year, Month);
message_doc(AccountId, MediaId) ->
    case open_accountdb_doc(AccountId, MediaId, kzd_box_message:type()) of
        {'ok', MediaJObj} ->
            SourceId = kzd_box_message:source_id(MediaJObj),
            case fetch_vmbox_messages(AccountId, SourceId) of
                {'ok', VMBoxMsgs} ->
                    merge_metadata(MediaId, MediaJObj, VMBoxMsgs);
                {'error', _}=E ->
                    E
            end;
        {'error', _R}=E ->
            lager:warning("failed to load voicemail message ~s: ~p", [MediaId, _R]),
            E
    end.

-spec merge_metadata(ne_binary(), kz_json:object(), kz_json:objects()) -> db_ret().
merge_metadata(MediaId, MediaJObj, VMBoxMsgs) ->
    case kz_json:find_value(<<"media_id">>, MediaId, VMBoxMsgs) of
        'undefined' -> {'error', 'not_found'};
        Metadata -> {'ok', kzd_box_message:set_metadata(Metadata, MediaJObj)}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc fetch vmbox doc from db. It will include metadata if IncludeMessages
%% set to true, otherwise would delete it from doc.
%% @end
%%--------------------------------------------------------------------
-spec load_vmbox(ne_binary(), ne_binary()) -> db_ret().
load_vmbox(AccountId, BoxId) ->
    load_vmbox(AccountId, BoxId, 'true').

-spec load_vmbox(ne_binary(), ne_binary(), boolean()) -> db_ret().
load_vmbox(AccountId, BoxId, IncludeMessages) ->
    case open_accountdb_doc(AccountId, BoxId, kzd_voicemail_box:type()) of
        {'ok', JObj} -> maybe_include_messages(AccountId, BoxId, JObj, IncludeMessages);
        {'error', _R}=E ->
            lager:debug("failed to open vmbox ~s: ~p", [BoxId, _R]),
            E
    end.

-spec maybe_include_messages(ne_binary(), ne_binary(), kz_json:object(), boolean()) -> {'ok', kz_json:object()}.
maybe_include_messages(AccountId, BoxId, JObj, 'true') ->
    VmMessages = kz_json:get_value(?VM_KEY_MESSAGES, JObj, []),
    AllMsg = fetch_modb_messages(AccountId, BoxId, VmMessages),
    {'ok', kz_json:set_value(?VM_KEY_MESSAGES, AllMsg, JObj)};
maybe_include_messages(_AccountId, _BoxId, JObj, _) ->
    {'ok', kz_json:delete_key(?VM_KEY_MESSAGES, JObj)}.

%%--------------------------------------------------------------------
%% @public
%% @doc Get vmbox summary view results from accountdb and merge
%% its message count with MODB vmbox count
%% @end
%%--------------------------------------------------------------------
-spec vmbox_summary(ne_binary()) -> db_ret().
vmbox_summary(AccountId) ->
    AccountDb = kz_util:format_account_id(AccountId, 'encoded'),
    case kz_datamgr:get_results(AccountDb, ?BOX_MESSAGES_CB_LIST, []) of
        {'ok', JObjs} ->
            Res = [kz_json:get_value(<<"value">>, JObj) || JObj <- JObjs],
            MODBRes = modb_count_summary(AccountId),
            {'ok', merge_summary_results(Res, MODBRes)};
        {'error', _R}=E ->
            lager:debug("error fetching vmbox_summary for account ~s: ~p", [AccountId, _R]),
            E
    end.

-spec modb_count_summary(ne_binary()) -> kz_json:objects().
modb_count_summary(AccountId) ->
    Opts = ['reduce', 'group'],
    ViewOptsList = get_range_view(AccountId, Opts),
    [Res || Res <- results_from_modbs(AccountId, ?COUNT_BY_VMBOX, ViewOptsList, []), Res =/= []].

-spec merge_summary_results(kz_json:objects(), kz_json:objects()) -> kz_json:objects().
merge_summary_results(BoxSummary, MODBSummary) ->
    lists:foldl(fun(JObj, Acc) ->
                    BoxId = kz_json:get_value(<<"id">>, JObj),
                    case kz_json:find_value(<<"key">>, BoxId, MODBSummary) of
                        'undefined' ->
                            [JObj | Acc];
                        J ->
                            BCount = kz_json:get_integer_value(?VM_KEY_MESSAGES, JObj, 0),
                            MCount = kz_json:get_integer_value(<<"value">>, J, 0),
                            [kz_json:set_value(?VM_KEY_MESSAGES, BCount + MCount, JObj) | Acc]
                    end
                end
                , [], BoxSummary).

%%--------------------------------------------------------------------
%% @public
%% @doc fetch all messages for a vmbox
%% @end
%%--------------------------------------------------------------------
-spec messages(ne_binary(), ne_binary()) -> kz_json:objects().
messages(AccountId, BoxId) ->
    % first get messages metadata from vmbox for backward compatibility
    case fetch_vmbox_messages(AccountId, BoxId) of
        {'ok', Msgs} -> fetch_modb_messages(AccountId, BoxId, Msgs);
        _ -> fetch_modb_messages(AccountId, BoxId, [])
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc fetch message metadata from db, will take care of previous
%% message metadata in vmbox.
%% @end
%%--------------------------------------------------------------------
-spec message(ne_binary(), ne_binary()) -> db_ret().
message(AccountId, MessageId) ->
    case message_doc(AccountId, MessageId) of
        {'ok', []} -> {'error', 'not_found'};
        {'ok', Msg} -> {'ok', kzd_box_message:metadata(Msg)};
        {'error', _}=E ->
            E
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc Set a message folder, returning the new updated message on success
%% or the old message on failed update
%% @end
%%--------------------------------------------------------------------
-spec set_folder(ne_binary(), kz_json:object(), ne_binary()) -> db_ret().
set_folder(Folder, Message, AccountId) ->
    MessageId = kzd_box_message:media_id(Message),
    FromFolder = kzd_box_message:folder(Message, ?VM_FOLDER_NEW),
    lager:info("setting folder for message ~s to ~s", [MessageId, Folder]),
    case maybe_set_folder(FromFolder, Folder, MessageId, AccountId, Message) of
        {'ok', _}=OK -> OK;
        {'error', _} -> {'error', Message}
    end.

-spec maybe_set_folder(ne_binary(), ne_binary(), ne_binary(), ne_binary(), kz_json:object()) -> db_ret().
maybe_set_folder(_, ?VM_FOLDER_DELETED=ToFolder, MessageId, AccountId, _) ->
    % ensuring that message is really deleted
    update_folder(ToFolder, MessageId, AccountId);
maybe_set_folder(FromFolder, FromFolder, ?MATCH_MODB_PREFIX(_, _, _), _, Msg) -> {'ok', Msg};
maybe_set_folder(FromFolder, FromFolder, MessageId, AccountId, _) ->
    lager:info("folder is same, but doc is in accountdb, move it to modb"),
    update_message_doc(AccountId, MessageId);
maybe_set_folder(_FromFolder, ToFolder, MessageId, AccountId, _) ->
    update_folder(ToFolder, MessageId, AccountId).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec update_folder(ne_binary(), ne_binary() | ne_binaries(), ne_binary()) -> db_ret().
update_folder(_, 'undefined', _) ->
    {'error', 'attachment_undefined'};
update_folder(Folder, MessageId, AccountId) when is_binary(MessageId) ->
    Fun = [fun(JObj) ->
               apply_folder(Folder, JObj)
           end
          ],
    case retry_conflict(update_message_doc(AccountId, MessageId, Fun)) of
        {'ok', J} -> {'ok', kzd_box_message:metadata(J)};
        {'error', R}=E ->
            lager:info("error while updating folder ~s ~p", [Folder, R]),
            E
    end;
update_folder(Folder, MsgIds, AccountId) ->
    Fun = [fun(JObj) ->
               apply_folder(Folder, JObj)
           end
          ],
    {'ok', update_multi_messages(AccountId, MsgIds, Fun)}.

-spec apply_folder(ne_binary(), kz_json:object()) -> kz_json:object().
apply_folder(?VM_FOLDER_DELETED, Doc) ->
    Metadata = kzd_box_message:set_folder_deleted(kzd_box_message:metadata(Doc)),
    kz_doc:set_soft_deleted(kzd_box_message:set_metadata(Metadata, Doc), 'true');
apply_folder(Folder, Doc) ->
    Metadata = kzd_box_message:set_folder(Folder, kzd_box_message:metadata(Doc)),
    kzd_box_message:set_metadata(Metadata, Doc).

%%--------------------------------------------------------------------
%% @private
%% @doc Update a single message doc and do migration when necessary
%% @end
%%--------------------------------------------------------------------
-type update_funs() :: [fun((kz_json:object()) -> kz_json:object())].

-spec update_message_doc(ne_binary(), ne_binary()) -> db_ret().
update_message_doc(AccountId, MsgId) ->
    update_message_doc(AccountId, MsgId, []).

-spec update_message_doc(ne_binary(), ne_binary(), update_funs()) -> db_ret().
update_message_doc(AccountId, MsgId, Funs) ->
    case message_doc(AccountId, MsgId) of
        {'ok', JObj} ->
            do_update_message_doc(AccountId, MsgId, JObj, Funs);
        {'error', _}=E -> E
    end.

-spec do_update_message_doc(ne_binary(), ne_binary(), kz_json:object(), update_funs()) -> db_ret().
do_update_message_doc(AccountId, ?MATCH_MODB_PREFIX(Year, Month, _)=MsgId, JObj, Funs) ->
    NewJObj = lists:foldl(fun(F, J) -> F(J) end, JObj, Funs),
    handle_update_result(MsgId, kazoo_modb:save_doc(AccountId, NewJObj, Year, Month));
do_update_message_doc(AccountId, MsgId, JObj, Funs) ->
    handle_update_result(MsgId, move_to_modb(AccountId, JObj, Funs, 'true')).

%%--------------------------------------------------------------------
%% @private
%% @doc Do update on multiple message docs and do migration when necessary
%% @end
%%--------------------------------------------------------------------
-type update_fold_ret() :: {ne_binaries(), [{ne_binary(), ne_binary()}]}.

-spec update_multi_messages(ne_binary(), ne_binaries(), update_funs()) -> kz_json:object().
update_multi_messages(AccountId, MsgIds, Funs) ->
    {VMBoxMIds, MODBMIds} = filter_messages_id(MsgIds, {[], []}),
    {SMoved, FMoved} = move_messages_to_modb(AccountId, VMBoxMIds, Funs),
    {SUpdated, FUpdated} = update_modb_messages(AccountId, MODBMIds, Funs),
    kz_json:from_list([{<<"succeeded">>, kz_json:from_list(lists:flatten(SMoved, SUpdated))}
                       ,{<<"failed">>, kz_json:from_list(lists:flatten(FMoved, FUpdated))}
                      ]
                     ).

-spec update_modb_messages(ne_binary(), ne_binaries(), update_funs()) -> update_fold_ret().
update_modb_messages(AccountId, Ids, Funs) ->
    update_modb_messages(AccountId, Ids, Funs, {[], []}).

-spec update_modb_messages(ne_binary(), ne_binaries(), update_funs(), update_fold_ret()) -> update_fold_ret().
update_modb_messages(_, [], _, Acc) -> Acc;
update_modb_messages(AccountId, [Id|Ids], Funs, {SAcc, FAcc}) ->
    case message_doc(AccountId, ?MATCH_MODB_PREFIX(Year, Month, _)=Id) of
        {'ok', JObj} ->
                NewJObj = lists:foldl(fun(F, J) -> F(J) end, JObj, Funs),
                case handle_update_result(Id, kazoo_modb:save_doc(AccountId, NewJObj, Year, Month)) of
                    {'ok', NJObj} ->
                        update_modb_messages(AccountId, Ids, Funs, {[NJObj | SAcc], FAcc});
                    {'error', R} ->
                        update_modb_messages(AccountId, Ids, Funs, {SAcc, [{Id, kz_util:to_binary(R)} | FAcc]})
                end;
        {'error', R} ->
            update_modb_messages(AccountId, Ids, Funs, {SAcc, [{Id, kz_util:to_binary(R)} | FAcc]})
    end.

-spec filter_messages_id(ne_binaries(), {ne_binaries(), ne_binaries()}) -> {ne_binaries(), ne_binaries()}.
filter_messages_id([], {V, M}) ->
    {V, M};
filter_messages_id([?MATCH_MODB_PREFIX(_, _, _)=Id|Rest], {V, M}) ->
    filter_messages_id(Rest, {V, [Id|M]});
filter_messages_id([Id|Rest], {V, M}) ->
    filter_messages_id(Rest, {[Id|V], M}).

-spec handle_update_result(ne_binary(), db_ret()) -> db_ret().
handle_update_result(?MATCH_MODB_PREFIX(_, _, _)=_Id, {'error', _R}=Error) ->
    lager:warning("failed to update voicemail message ~s: ~p", [_Id, _R]),
    Error;
handle_update_result(?MATCH_MODB_PREFIX(_, _, _), {'ok', _}=Res) -> Res;
handle_update_result(FromId, {'error', _R}=Error) ->
    lager:warning("failed move voicemail message ~s to modb: ~p", [FromId, _R]),
    Error;
handle_update_result(_, {'ok', _}=Res) -> Res.

%%--------------------------------------------------------------------
%% @public
%% @doc Move old voicemail media doc with message metadata to the MODB
%% @end
%%--------------------------------------------------------------------
-type modb_move_ret() :: [{ne_binary(), kz_json:object()}].
-type modb_move_acc() :: {modb_move_ret(), [ne_binary() | ne_binary()]}.

-spec move_messages_to_modb(ne_binary(), ne_binaries(), update_funs()) -> update_fold_ret().
move_messages_to_modb(_, [], _) -> {[], []};
move_messages_to_modb(AccountId, OldIds, Funs) ->
    {Moved, Failed} = move_messages_to_modb(AccountId, OldIds, Funs, {[], []}),
    _ = cleanup_moved_msgs(AccountId, Moved),
    Moved1 = [kzd_box_message:media_id(NJObj) || {_OldId, NJObj} <- Moved],
    {Moved1, Failed}.

-spec move_messages_to_modb(ne_binary(), ne_binaries(), update_funs(), modb_move_acc()) -> modb_move_ret().
move_messages_to_modb(_, [], _, Acc) -> Acc;
move_messages_to_modb(AccountId, [Id|Ids], Funs, {SAcc, FAcc}) ->
    case message_doc(AccountId, Id) of
        {'ok', JObj} ->
            case  handle_update_result(Id, move_to_modb(AccountId, JObj, Funs, 'false')) of
                {'ok', NJObj} ->
                    move_messages_to_modb(AccountId, Ids, Funs, {[{Id, NJObj}|SAcc], FAcc});
                {'error', R} ->
                    move_messages_to_modb(AccountId, Ids, Funs, {SAcc, [{Id, kz_util:to_binary(R)}, FAcc]})
            end;
        {'error', R} -> move_messages_to_modb(AccountId, Ids, Funs, {SAcc, [{Id, kz_util:to_binary(R)}, FAcc]})
    end.

-spec move_to_modb(ne_binary(), kz_json:object(), update_funs(), boolean()) -> db_ret().
move_to_modb(AccountId, JObj, Funs, 'true') ->
    case do_move_to_modb(AccountId, JObj, Funs) of
        {'ok', NJObj}=OK ->
            Moved = [{kz_doc:id(JObj)}, NJObj],
            _ = cleanup_moved_msgs(AccountId, Moved),
            OK;
        {'error', _}=E -> E
    end;
move_to_modb(AccountId, JObj, Funs, 'false') ->
    do_move_to_modb(AccountId, JObj, Funs).

-spec do_move_to_modb(ne_binary(), kz_json:object(), update_funs()) -> db_ret().
do_move_to_modb(AccountId, JObj, Funs) ->
    Created = kz_doc:created(JObj),
    {{Year, Month, _}, _} = calendar:gregorian_seconds_to_datetime(Created),

    FromDb = get_db(AccountId),
    FromId = kz_doc:id(JObj),
    ToDb = kazoo_modb:get_modb(AccountId, Year, Month),
    ToId = <<(kz_util:to_binary(Year))/binary
              ,(kz_util:pad_month(Month))/binary
              ,"-"
              ,(kz_util:rand_hex_binary(16))/binary
           >>,

    TransformFuns = [fun(DestDoc) -> kzd_box_message:set_metadata(kzd_box_message:metadata(JObj), DestDoc) end
                     ,fun(DestDoc) -> update_media_id(ToId, DestDoc) end
                     ,fun(DestDoc) -> kz_json:set_value(<<"pvt_type">>, kzd_box_message:type(), DestDoc) end
                     | Funs
                    ],
    Options = [{'transform', fun(_, B) -> lists:foldl(fun(F, J) -> F(J) end, B, TransformFuns) end}],
    retry_conflict(kz_datamgr:move_doc(FromDb, FromId, ToDb, ToId, Options)).

-spec update_media_id(ne_binary(), kz_json:object()) -> kz_json:object().
update_media_id(MediaId, JObj) ->
    Metadata = kzd_box_message:set_media_id(MediaId, kzd_box_message:metadata(JObj)),
    kzd_box_message:set_metadata(Metadata, JObj).

-spec cleanup_moved_msgs(ne_binary(), modb_move_ret()) -> 'ok'.
cleanup_moved_msgs(_, []) -> 'ok';
cleanup_moved_msgs(AccountId, [{_, J1}|_]=Moved) ->
    AccountDb = get_db(AccountId),
    Fun = fun({OldId, NJObj}, Ids) ->
              NewId = kzd_box_message:media_id(NJObj),
              case kz_datamgr:del_doc(AccountDb, OldId) of
                  {'ok', _} -> 'ok';
                  {'error', _R} ->
                      lager:error("failed to remove vm media doc(old_id: ~s new_id: ~s): ~p"
                                  ,[OldId, NewId, _R]
                                 )
              end,
              [OldId | Ids]
          end,
    OldIds = lists:foldl(Fun, [], Moved),
    BoxId = kzd_box_message:source_id(J1),
    _ = remove_moved_msgs_from_vmbox(AccountId, BoxId, OldIds),
    'ok'.

-spec remove_moved_msgs_from_vmbox(ne_binary(), ne_binary(), ne_binaries()) -> db_ret().
remove_moved_msgs_from_vmbox(AccountId, BoxId, OldIds) ->
    case open_accountdb_doc(AccountId, BoxId, kzd_voicemail_box:type()) of
        {'ok', VMBox} ->
            Messages = kz_json:get_value(?VM_KEY_MESSAGES, VMBox, []),
            NewMessages = lists:filter(fun(M) ->
                                           not lists:member(kzd_box_message:media_id(M), OldIds)
                                       end
                                       ,Messages
                                      ),
            NewBoxJObj = kz_json:set_value(?VM_KEY_MESSAGES, NewMessages, VMBox),
            case retry_conflict(kz_datamgr:save_doc(get_db(AccountId), NewBoxJObj)) of
                {'ok', _}=OK -> OK;
                {'error', _R}=E ->
                    lager:error("could not update mailbox messages array after moving voicemail messages to MODb ~s: ~s", [BoxId, _R]),
                    E
            end;
        {'error', _R}=E ->
            lager:error("unable to open mailbox for update messages array after moving voicemail messages to MODb ~s: ~s", [BoxId, _R]),
            E
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc Count non-deleted messages
%% @end
%%--------------------------------------------------------------------
-spec count(ne_binary(), ne_binary()) -> non_neg_integer().
count(AccountId, BoxId) ->
    {New, Saved} = count_per_folder(AccountId, BoxId),
    New + Saved.

count_by_owner(?MATCH_ACCOUNT_ENCODED(_)=AccountDb, OwnerId) ->
    AccountId = kz_util:format_account_id(AccountDb),
    count_by_owner(AccountId, OwnerId);
count_by_owner(AccountId, OwnerId) ->
    ViewOpts = [{'key', [OwnerId, <<"vmbox">>]}],

    case kz_datamgr:get_results(get_db(AccountId), <<"cf_attributes/owned">>, ViewOpts) of
        {'ok', []} ->
            lager:info("voicemail box owner is not found"),
            {0, 0};
        {'ok', [Owned|_]} ->
            VMBoxId = kz_json:get_value(<<"value">>, Owned),
            count_per_folder(AccountId, VMBoxId);
        {'error', _R} ->
            lager:info("unable to lookup vm counts by owner: ~p", [_R]),
            {0, 0}
    end.

-spec count_per_folder(ne_binary(), ne_binary()) -> {non_neg_integer(), non_neg_integer()}.
count_per_folder(AccountId, BoxId) ->
    % first count messages from vmbox for backward compatibility
    case fetch_vmbox_messages(AccountId, BoxId) of
        {'ok', Msgs} ->
            New = kzd_box_message:count_folder(Msgs, [?VM_FOLDER_NEW]),
            Saved = kzd_box_message:count_folder(Msgs, [?VM_FOLDER_SAVED]),
            count_modb_messages(AccountId, BoxId, {New, Saved});
        _ -> count_modb_messages(AccountId, BoxId, {0, 0})
    end.

-spec count_modb_messages(ne_binary(), ne_binary(), {non_neg_integer(), non_neg_integer()}) -> {non_neg_integer(), non_neg_integer()}.
count_modb_messages(AccountId, BoxId, {ANew, ASaved}=AccountDbCounts) ->
    Opts = ['reduce'
            ,'group'
            ,{'group_level', 2}
            ,{'startkey', [BoxId]}
            ,{'endkey', [BoxId, kz_json:new()]}
           ],
    ViewOptions = get_range_view(AccountId, Opts),

    case results_from_modbs(AccountId, ?MODB_COUNT_VIEW, ViewOptions, []) of
        [] ->
            AccountDbCounts;
        Results ->
            {MNew, MSaved} = kzd_box_message:normalize_count(Results),
            {ANew + MNew, ASaved + MSaved}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc Try to find changes made into messages list and return a tuple of
%% messages that changed and messages that are not changed and must go
%% into vmbox messages list.
%% @end
%%--------------------------------------------------------------------
-spec find_message_differences(ne_binary(), ne_binary(), kz_json:objects()) ->
                                {kz_json:objects(), kz_json:objects()}.
find_message_differences(AccountId, BoxId, DirtyJObj) ->
    Messages = messages(AccountId, BoxId),
    find_message_differences(DirtyJObj, Messages).

find_message_differences(ReqJ, Messages) ->
    Fun = fun(MsgJ, {DiffAcc, VMMsgAcc}) ->
              MessageId = kzd_box_message:media_id(MsgJ),
              case kz_json:find_value(<<"media_id">>, MessageId, ReqJ) of
                  'undefined' ->
                      {[MsgJ | DiffAcc], VMMsgAcc};
                  J ->
                      case kz_json:are_identical(MsgJ, J) of
                          'true' -> {DiffAcc, maybe_add_to_vmbox(MsgJ, VMMsgAcc)};
                          'false' -> {[J | DiffAcc], VMMsgAcc}
                      end
              end
          end,
    lists:foldl(Fun , {[], []}, Messages).

maybe_add_to_vmbox(M, Acc) ->
    maybe_add_to_vmbox(M, kzd_box_message:media_id(M), Acc).

maybe_add_to_vmbox(_M, ?MATCH_MODB_PREFIX(_Year, _Month, _), Acc) ->
    Acc;
maybe_add_to_vmbox(M, _Id, Acc) ->
    [M | Acc].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec media_url(ne_binary(), ne_binary() | kz_json:object()) -> binary().
media_url(AccountId, ?JSON_WRAPPER(_)=Message) ->
    media_url(AccountId, kzd_box_message:media_id(Message));
media_url(AccountId, MessageId) ->
    case message_doc(AccountId, MessageId) of
        {'ok', Message} ->
            kz_media_url:playback(Message, Message);
        {'error', _} -> <<>>
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Abstract database operations
%% @end
%%--------------------------------------------------------------------
-spec open_modb_doc(ne_binary(), kazoo_data:docid(), ne_binary(), ne_binary()) -> kz_json:object().
open_modb_doc(AccountId, DocId, Year, Month) ->
    case kazoo_modb:open_doc(AccountId, DocId, Year, Month) of
        {'ok', _}=OK -> OK;
        {'error', _}=E -> E
    end.

-spec open_accountdb_doc(ne_binary(), kazoo_data:docid(), ne_binary()) -> kz_json:object().
open_accountdb_doc(AccountId, DocId, Type) ->
    case kz_datamgr:open_doc(get_db(AccountId), DocId) of
        {'ok', D} -> check_doc_type(D, Type, kz_doc:type(D));
        {'error', _}=E -> E
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Protect against returning wrong doc when expected type is not matched
%% (especially for requests from crossbar)
%% @end
%%--------------------------------------------------------------------
-spec check_doc_type(kz_json:object(), ne_binary(), ne_binary()) -> db_ret().
check_doc_type(Doc, Type, Type) ->
    {'ok', Doc};
check_doc_type(_Doc, _ExpectedType, _DocType) ->
    {'error', 'not_found'}.

-spec fetch_vmbox_messages(ne_binary(), ne_binary()) -> db_ret().
fetch_vmbox_messages(AccountId, BoxId) ->
    case open_accountdb_doc(AccountId, BoxId, kzd_voicemail_box:type()) of
        {'ok', BoxJObj} -> {'ok', kz_json:get_value(?VM_KEY_MESSAGES, BoxJObj, [])};
        {'error', _}=E ->
            lager:debug("error fetching voicemail messages for ~s from accountid ~s", [BoxId, AccountId]),
            E
    end.

-spec fetch_modb_messages(ne_binary(), ne_binary(), kz_json:objects()) -> kz_json:objects().
fetch_modb_messages(AccountId, DocId, VMBoxMsg) ->
    ViewOpts = [{'key', DocId}
                ,'include_docs'
               ],
    ViewOptsList = get_range_view(AccountId, ViewOpts),

    ModbResults = [kzd_box_message:metadata(kz_json:get_value(<<"doc">>, Msg))
                   || Msg <- results_from_modbs(AccountId, ?MODB_LISTING_BY_MAILBOX, ViewOptsList, [])
                      ,Msg =/= []
                  ],
    VMBoxMsg ++ ModbResults.

-spec results_from_modbs(ne_binary(), ne_binary(), kz_proplist(), kz_json:objects()) -> kz_json:objects().
results_from_modbs(_AccountId, _View, [], ViewResults) ->
    ViewResults;
results_from_modbs(AccountId, View, [ViewOpts|ViewOptsList], Acc) ->
    case kazoo_modb:get_results(AccountId, View, ViewOpts) of
        {'ok', []} -> results_from_modbs(AccountId, View, ViewOptsList, Acc);
        {'ok', Msgs} -> results_from_modbs(AccountId, View, ViewOptsList, Msgs ++ Acc);
        {'error', _}=_E ->
            lager:debug("error when fetching voicemail message for ~s from modb ~s"
                        ,[props:get_value('key', ViewOpts), props:get_value('modb', ViewOpts)]
                       ),
            results_from_modbs(AccountId, View, ViewOptsList, Acc)
    end.

-spec get_range_view(ne_binary(), kz_proplist()) -> kz_proplists().
get_range_view(AccountId, ViewOpts) ->
    To = kz_util:current_tstamp(),
    From = To - ?RETENTION_DAYS(?RETENTION_DURATION),

    [ begin
          {AccountId, Year, Month} = kazoo_modb_util:split_account_mod(MODB),
          [{'year', Year}
           ,{'month', Month}
           ,{'modb', MODB}
           | ViewOpts
          ]
      end || MODB <- kazoo_modb:get_range(AccountId, From, To)
    ].

-spec retry_conflict(fun(() -> db_ret())) -> db_ret().
-spec retry_conflict(fun(() -> db_ret()), 0..3) -> db_ret().
retry_conflict(Fun) ->
    retry_conflict(Fun, 3).

retry_conflict(_, 0) -> {'error', 'conflict'};
retry_conflict(Fun, Tries) ->
    case Fun() of
        {'error', 'conflict'} -> retry_conflict(Fun, Tries - 1);
        Other -> Other
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec publish_voicemail_saved_notify(ne_binary(), ne_binary(), kapps_call:call(), pos_integer(), kz_proplist()) ->
                                    {'ok', kz_json:object()} |
                                    {'timeout', kz_json:object()} |
                                    {'error', any()}.
publish_voicemail_saved_notify(MediaId, BoxId, Call, Length, Props) ->
    MaybeTranscribe = props:get_value(<<"Transcribe-Voicemail">>, Props),
    Transcription = maybe_transcribe(Call, MediaId, MaybeTranscribe),

    NotifyProp = [{<<"From-User">>, kapps_call:from_user(Call)}
                  ,{<<"From-Realm">>, kapps_call:from_realm(Call)}
                  ,{<<"To-User">>, kapps_call:to_user(Call)}
                  ,{<<"To-Realm">>, kapps_call:to_realm(Call)}
                  ,{<<"Account-DB">>, kapps_call:account_db(Call)}
                  ,{<<"Account-ID">>, kapps_call:account_id(Call)}
                  ,{<<"Voicemail-Box">>, BoxId}
                  ,{<<"Voicemail-Name">>, MediaId}
                  ,{<<"Caller-ID-Number">>, get_caller_id_number(Call)}
                  ,{<<"Caller-ID-Name">>, get_caller_id_name(Call)}
                  ,{<<"Voicemail-Timestamp">>, new_timestamp()}
                  ,{<<"Voicemail-Length">>, Length}
                  ,{<<"Voicemail-Transcription">>, Transcription}
                  ,{<<"Call-ID">>, kapps_call:call_id(Call)}
                  | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                 ],

    lager:debug("notifying of voicemail saved"),
    kz_amqp_worker:call_collect(NotifyProp
                                ,fun kapi_notifications:publish_voicemail/1
                                ,fun collecting/1
                                ,30 * ?MILLISECONDS_IN_SECOND
                               ).


-spec publish_voicemail_saved(pos_integer(), ne_binary(), kapps_call:call(), ne_binary(), gregorian_seconds()) -> 'ok'.
publish_voicemail_saved(Length, BoxId, Call, MediaId, Timestamp) ->
    Prop = [{<<"From-User">>, kapps_call:from_user(Call)}
            ,{<<"From-Realm">>, kapps_call:from_realm(Call)}
            ,{<<"To-User">>, kapps_call:to_user(Call)}
            ,{<<"To-Realm">>, kapps_call:to_realm(Call)}
            ,{<<"Account-DB">>, kapps_call:account_db(Call)}
            ,{<<"Account-ID">>, kapps_call:account_id(Call)}
            ,{<<"Voicemail-Box">>, BoxId}
            ,{<<"Voicemail-Name">>, MediaId}
            ,{<<"Caller-ID-Number">>, get_caller_id_number(Call)}
            ,{<<"Caller-ID-Name">>, get_caller_id_name(Call)}
            ,{<<"Voicemail-Timestamp">>, Timestamp}
            ,{<<"Voicemail-Length">>, Length}
            ,{<<"Call-ID">>, kapps_call:call_id(Call)}
            | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_notifications:publish_voicemail_saved(Prop),
    lager:debug("published voicemail_saved for ~s", [BoxId]).

-spec collecting(kz_json:objects()) -> boolean().
collecting([JObj|_]) ->
    case kapi_notifications:notify_update_v(JObj)
        andalso kz_json:get_value(<<"Status">>, JObj)
    of
        <<"completed">> -> 'true';
        <<"failed">> -> 'true';
        _ -> 'false'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_transcribe(ne_binary(), ne_binary(), boolean()) ->
                              api_object().
maybe_transcribe(AccountId, MediaId, 'true') ->
    Db = get_db(AccountId, MediaId),
    {'ok', MediaDoc} = kz_datamgr:open_doc(Db, MediaId),
    case kz_doc:attachment_names(MediaDoc) of
        [] ->
            lager:warning("no audio attachments on media doc ~s: ~p", [MediaId, MediaDoc]),
            'undefined';
        [AttachmentId|_] ->
            case kz_datamgr:fetch_attachment(Db, MediaId, AttachmentId) of
                {'ok', Bin} ->
                    lager:info("transcribing first attachment ~s", [AttachmentId]),
                    maybe_transcribe(Db, MediaDoc, Bin, kz_doc:attachment_content_type(MediaDoc, AttachmentId));
                {'error', _E} ->
                    lager:info("error fetching vm: ~p", [_E]),
                    'undefined'
            end
    end;
maybe_transcribe(_, _, 'false') -> 'undefined'.

-spec maybe_transcribe(ne_binary(), kz_json:object(), binary(), api_binary()) ->
                              api_object().
maybe_transcribe(_, _, _, 'undefined') -> 'undefined';
maybe_transcribe(_, _, <<>>, _) -> 'undefined';
maybe_transcribe(Db, MediaDoc, Bin, ContentType) ->
    case kapps_speech:asr_freeform(Bin, ContentType) of
        {'ok', Resp} ->
            lager:info("transcription resp: ~p", [Resp]),
            MediaDoc1 = kz_json:set_value(<<"transcription">>, Resp, MediaDoc),
            _ = kz_datamgr:ensure_saved(Db, MediaDoc1),
            is_valid_transcription(kz_json:get_value(<<"result">>, Resp)
                                   ,kz_json:get_value(<<"text">>, Resp)
                                   ,Resp
                                  );
        {'error', _E} ->
            lager:info("error transcribing: ~p", [_E]),
            'undefined'
    end.

-spec is_valid_transcription(api_binary(), binary(), kz_json:object()) ->
                                    api_object().
is_valid_transcription(<<"success">>, ?NE_BINARY, Resp) -> Resp;
is_valid_transcription(_Res, _Txt, _) ->
    lager:info("not valid transcription: ~s: '~s'", [_Res, _Txt]),
    'undefined'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns the Universal Coordinated Time (UTC) reported by the
%% underlying operating system (local time is used if universal
%% time is not available) as number of gregorian seconds starting
%% with year 0.
%% @end
%%--------------------------------------------------------------------
-spec new_timestamp() -> gregorian_seconds().
new_timestamp() -> kz_util:current_tstamp().

-spec get_caller_id_name(kapps_call:call()) -> ne_binary().
get_caller_id_name(Call) ->
    CallerIdName = kapps_call:caller_id_name(Call),
    case kapps_call:kvs_fetch('prepend_cid_name', Call) of
        'undefined' -> CallerIdName;
        Prepend -> Pre = <<(kz_util:to_binary(Prepend))/binary, CallerIdName/binary>>,
                   kz_util:truncate_right_binary(Pre,
                           kzd_schema_caller_id:external_name_max_length())
    end.

-spec get_caller_id_number(kapps_call:call()) -> ne_binary().
get_caller_id_number(Call) ->
    CallerIdNumber = kapps_call:caller_id_number(Call),
    case kapps_call:kvs_fetch('prepend_cid_number', Call) of
        'undefined' -> CallerIdNumber;
        Prepend -> Pre = <<(kz_util:to_binary(Prepend))/binary, CallerIdNumber/binary>>,
                   kz_util:truncate_right_binary(Pre,
                           kzd_schema_caller_id:external_name_max_length())
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Migrate all messages in vmbox into the new modb format
%% @end
%%--------------------------------------------------------------------
-spec migrate() -> 'ok'.
migrate() ->
    _ = [migrate(Id)|| Id <- kapps_util:get_all_accounts('raw')],
    'ok'.

-spec migrate(ne_binary()) -> 'ok'.
migrate(AccountId) ->
    AccountDb = get_db(AccountId),
    case kz_datamgr:get_results(AccountDb, ?BOX_MESSAGES_CB_LIST, []) of
        {'ok', []} -> lager:debug("no voicemail boxes in ~s", [AccountDb]);
        {'ok', View} ->
            _ = [migrate(AccountId, kz_json:get_value(<<"value">>, V)) || V <- View],
            lager:debug("migrated all messages of ~b mail boxes in ~s to modbs", [length(View), AccountDb]);
        {'error', _E} ->
            lager:debug("failed to get voicemail boxes in ~s: ~p", [AccountDb, _E])
    end.

-spec migrate(ne_binary(), ne_binary() | kz_json:object()) -> 'ok'.
migrate(AccountId, ?JSON_WRAPPER(_)=Box) ->
    migrate(AccountId, kz_json:get_value(<<"id">>, Box));
migrate(AccountId, BoxId) ->
    Msgs = messages(AccountId, BoxId),
    Ids = lists:filter(fun(M) -> maybe_migrate_to_modb(kzd_box_message:media_id(M)) end, Msgs),
    _ = update_multi_messages(AccountId, Ids, []),
    'ok'.

-spec maybe_migrate_to_modb(ne_binary()) -> boolean().
maybe_migrate_to_modb(?MATCH_MODB_PREFIX(_, _, _)) -> 'false';
maybe_migrate_to_modb(_) -> 'true'.

%%--------------------------------------------------------------------
%% @private
%% @doc Clean old heard voice messages from db
%% @end
%%--------------------------------------------------------------------
-spec cleanup_heard_voicemail(ne_binary()) -> 'ok'.
cleanup_heard_voicemail(AccountId) ->
    Today = kz_util:current_tstamp(),
    Duration = ?RETENTION_DURATION,
    DurationS = ?RETENTION_DAYS(Duration),
    lager:debug("retaining messages for ~p days, delete those older for ~s", [Duration, AccountId]),

    AccountDb = get_db(AccountId),
    case kz_datamgr:get_results(AccountDb, ?BOX_MESSAGES_CB_LIST, []) of
        {'ok', []} -> lager:debug("no voicemail boxes in ~s", [AccountDb]);
        {'ok', View} ->
            cleanup_heard_voicemail(AccountId
                                    ,Today - DurationS
                                    ,[kz_json:get_value(<<"value">>, V) || V <- View]
                                   ),
            lager:debug("cleaned up ~b voicemail boxes in ~s", [length(View), AccountDb]);
        {'error', _E} ->
            lager:debug("failed to get voicemail boxes in ~s: ~p", [AccountDb, _E])
    end.

-spec cleanup_heard_voicemail(ne_binary(), pos_integer(), kz_proplist()) -> 'ok'.
cleanup_heard_voicemail(AccountId, Timestamp, Boxes) ->
    _ = [cleanup_voicemail_box(AccountId, Timestamp, Box) || Box <- Boxes],
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc Filter out old messages in vmbox and soft delete them
%% @end
%%--------------------------------------------------------------------
-spec cleanup_voicemail_box(ne_binary(), pos_integer(), kz_json:object()) -> 'ok'.
cleanup_voicemail_box(AccountId, Timestamp, Box) ->
    BoxId = kz_json:get_value(<<"id">>, Box),
    Msgs = messages(AccountId, BoxId),
    case
        lists:partition(
            fun(Msg) ->
                %% must be old enough, and not in the NEW folder
                kz_json:get_integer_value(<<"timestamp">>, Msg) < Timestamp
                    andalso kz_json:get_value(<<"folder">>, Msg) =/= <<"new">>
            end
            ,Msgs
        )
    of
        {[], _} ->
            lager:debug("there are no old messages to remove from ~s", [BoxId]);
        {Older, _} ->
            lager:debug("there are ~b old messages to remove", [length(Older)]),

            Ids = [kzd_box_message:media_id(M) || M <- Older],
            _ = update_folder(?VM_FOLDER_DELETED, Ids, AccountId),
            lager:debug("soft-deleted old messages"),
            lager:debug("updated messages in voicemail box ~s", [BoxId])
    end.
