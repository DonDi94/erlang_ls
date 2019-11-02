-module(erlang_ls_index).

-callback index(erlang_ls_document:document()) -> ok.

-export([ find_and_index_file/1
        , index/1
        , initialize/1
        , start_link/1
        ]).

-export([ app_path/0
        , include_path/0
        , deps_path/0
        , otp_path/0
        ]).

-type index() :: erlang_ls_completion_index
               | erlang_ls_references_index
               | erlang_ls_specs_index.

-define( INDEXES
       , [ erlang_ls_completion_index
         , erlang_ls_references_index
         , erlang_ls_specs_index
         ]
       ).

-include("erlang_ls.hrl").

%%==============================================================================
%% External functions
%%==============================================================================

-spec initialize(map()) -> ok.
initialize(_Config) ->
  %% TODO: This could be done asynchronously,
  %%       but we need a way to know when indexing is done,
  %%       or the tests will be flaky.

  %% At initialization, we currently index only the app path.
  %% deps and otp paths will be indexed on demand.
  [index_dir(Dir) || Dir <- app_path()],
  ok.

-spec index(erlang_ls_document:document()) -> ok.
index(Document) ->
  Uri    = erlang_ls_document:uri(Document),
  ok     = erlang_ls_db:store(documents, Uri, Document),
  [Index:index(Document) || Index <- ?INDEXES],
  ok.

-spec start_link(index()) -> {ok, pid()}.
start_link(Index) ->
  gen_server:start_link({local, Index}, ?MODULE, Index, []).

%%==============================================================================
%% Internal functions
%%==============================================================================

%% @edoc Index a directory.
%%
%% Index all .erl and .hrl files contained in the given directory, recursively.
%% If indexing fails for a specific file, the file is skipped.
%% Return the number of correctly and incorrectly indexed files.
%%
-spec index_dir(string()) -> {non_neg_integer(), non_neg_integer()}.
index_dir(Dir) ->
  lager:info("Indexing directory. [dir=~s]", [Dir]),
  F = fun(FileName, {Succeeded, Failed}) ->
          case try_index_file(list_to_binary(FileName)) of
            ok              -> {Succeeded +1, Failed};
            {error, _Error} -> {Succeeded, Failed + 1}
          end
      end,
  {Time, {Succeeded, Failed}} = timer:tc( filelib
                                        , fold_files
                                        , [ Dir
                                          , ".*\\.[e,h]rl$"
                                          , true
                                          , F
                                          , {0, 0} ]),
  lager:info("Finished indexing directory. [dir=~s] [time=~p]"
             "[succeeded=~p] "
             "[failed=~p]", [Time/1000/1000, Dir, Succeeded, Failed]),
  {Succeeded, Failed}.

%% @edoc Try indexing a file.
-spec try_index_file(binary()) -> ok | {error, any()}.
try_index_file(FullName) ->
  try
    lager:debug("Indexing file. [filename=~s]", [FullName]),
    {ok, Text} = file:read_file(FullName),
    Uri        = erlang_ls_uri:uri(FullName),
    Document   = erlang_ls_document:create(Uri, Text),
    ok         = index(Document)
  catch Type:Reason:St ->
      lager:error("Error indexing file "
                  "[filename=~s] "
                  "~p:~p:~p", [FullName, Type, Reason, St]),
      {error, {Type, Reason}}
  end.

-spec find_and_index_file(string()) ->
   {ok, uri()} | {error, any()}.
find_and_index_file(FileName) ->
  Paths = lists:append([ app_path()
                       , deps_path()
                       , otp_path()
                       ]),
  case file:path_open(Paths, list_to_binary(FileName), [read]) of
    {ok, IoDevice, FullName} ->
      %% TODO: Avoid opening file twice
      file:close(IoDevice),
      try_index_file(FullName),
      {ok, erlang_ls_uri:uri(FullName)};
    {error, Error} ->
      {error, Error}
  end.

-spec app_path() -> [string()].
app_path() ->
  {ok, RootUri} = erlang_ls_config:get(root_uri),
  RootPath = binary_to_list(erlang_ls_uri:path(RootUri)),
  resolve_paths( [ [RootPath, "src"]
                 , [RootPath, "test"]
                 , [RootPath, "include"]
                 ]).

-spec include_path() -> [string()].
include_path() ->
  {ok, RootUri} = erlang_ls_config:get(root_uri),
  RootPath = binary_to_list(erlang_ls_uri:path(RootUri)),
  {ok, IncludeDirs} = erlang_ls_config:get(include_dirs),
  Paths = [resolve_paths( [ [RootPath, Dir] ]) || Dir <- IncludeDirs],
  lists:append(Paths).

-spec deps_path() -> [string()].
deps_path() ->
  {ok, RootUri} = erlang_ls_config:get(root_uri),
  RootPath = binary_to_list(erlang_ls_uri:path(RootUri)),
  {ok, Dirs} = erlang_ls_config:get(deps_dirs),
  Paths = [ resolve_paths( [ [RootPath, Dir, "src"]
                           , [RootPath, Dir, "test"]
                           , [RootPath, Dir, "include"]
                           ])
            || Dir <- Dirs
          ],
  lists:append(Paths).

-spec otp_path() -> [string()].
otp_path() ->
  {ok, Root} = erlang_ls_config:get(otp_path),
  resolve_paths( [ [Root, "lib", "*", "src"]
                 , [Root, "lib", "*", "include"]
                 ]).

-spec resolve_paths([[string()]]) -> [[string()]].
resolve_paths(PathSpecs) ->
  lists:append([resolve_path(PathSpec) || PathSpec <- PathSpecs]).

-spec resolve_path([string()]) -> [string()].
resolve_path(PathSpec) ->
  Path = filename:join(PathSpec),
  Paths = [[P | subdirs(P)] || P <- filelib:wildcard(Path)],
  lists:append(Paths).

%% Returns all subdirectories for the provided path
-spec subdirs(string()) -> [string()].
subdirs(Path) ->
  subdirs(Path, []).

-spec subdirs(string(), [string()]) -> [string()].
subdirs(Path, Subdirs) ->
  case file:list_dir(Path) of
    {ok, Files}     -> subdirs_(Path, Files, Subdirs);
    {error, enoent} -> Subdirs
  end.

-spec subdirs_(string(), [string()], [string()]) -> [string()].
subdirs_(Path, Files, Subdirs) ->
  Fold = fun(F, Acc) ->
             FullPath = filename:join([Path, F]),
             case filelib:is_dir(FullPath) of
               true  -> subdirs(FullPath, [FullPath | Acc]);
               false -> Acc
             end
         end,
  lists:foldl(Fold, Subdirs, Files).
