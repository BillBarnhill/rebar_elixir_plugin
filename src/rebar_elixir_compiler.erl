%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009, 2010 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_elixir_compiler).
 
-export([compile/2,
         post_compile/2,
         clean/2,
         pre_eunit/2,
         preprocess/2
        ]).

-export([dotex_compile/2,
         dotex_compile/3]).



%% ===================================================================
%% Public API
%% ===================================================================

%% Supported configuration variables:
%%
%% * ex_first_files - First elixir files to compile
%% * elixir_opts - Erlang list of elixir compiler options
%%                 
%%                 For example, {elixir_opts, [{ignore_module_conflict, false}]}
%%

preprocess(Config, _) ->
    rebar_log:log(info, "Got to preprocess~n", []),
    rebar_erlc_compiler:compile(Config, ""),
    {ok, []}.

-spec compile(Config::rebar_config:config(), AppFile::file:filename()) -> 'ok'.
compile(Config, _AppFile) ->
    OldLevel = application:get_env(rebar, log_level),
    application:set_env(rebar, log_level, debug),

    {ok, OldCodePath} = fix_libdir_codepath(Config),
    ok = dotex_compile(Config, "ebin"),
    true = code:set_path(OldCodePath),
    application:set_env(rebar, log_level, OldLevel),
    ok.

-spec post_compile(Config::rebar_config:config(), AppFile::file:filename()) -> 'ok'.
post_compile(_, undefined) -> ok;
post_compile(Config, AppFile) ->
    case rebar_app_utils:is_app_src(AppFile) of
        true ->
            ActualAppFile = rebar_app_utils:app_src_to_app(AppFile),
            file:delete(ActualAppFile),
            erase({app_file, ActualAppFile}),
            rebar_otp_app:compile(Config, AppFile);
        false ->
            ok
    end.

-spec clean(Config::rebar_config:config(), AppFile::file:filename()) -> 'ok'.
clean(_Config, _AppFile) ->
    BeamFiles = rebar_utils:find_files("ebin", "^.*\\.beam\$"),
    rebar_file_utils:delete_each(BeamFiles),
    {ok, FileNames} = file:list_dir("ebin"),
    lists:foreach(fun (FN) ->
                          rebar_log:log(info, "Ebin dir has...~p~n", [FN])
                  end, FileNames),
    lists:foreach(
      fun(Dir) -> 
              delete_dir(Dir, dirs(Dir)) 
      end, dirs("ebin")),
    ok.


-spec pre_eunit(Config::rebar_config:config(), AppFile::file:filename()) -> 'ok'.
pre_eunit(Config, _AppFIle) ->
    dotex_compile(Config, ".eunit").

%% ===================================================================
%% .ex Compilation API
%% ===================================================================

-spec dotex_compile(Config::rebar_config:config(),
                     OutDir::file:filename()) -> 'ok'.
dotex_compile(Config, OutDir) ->
    dotex_compile(Config, OutDir, []).

dotex_compile(Config, OutDir, MoreSources) ->
    ExOpts = ex_opts(Config),
    OldCodePath = code:get_path(),
    %% Support the src_dirs option allowing multiple directories to
    %% contain elixir source. This might be used, for example, should
    %% eunit tests be separated from the core application source.
    SrcDirs = src_dirs(proplists:append_values(src_dirs, ExOpts)),
    FirstExs = rebar_config:get_local(Config, ex_first_files, []),
    start_engine(),
    {ok, FirstExsUnfiltered, RestExsUnfiltered} = gather_sources(FirstExs, SrcDirs, MoreSources),
    RecompileFilterFn = fun (Ex) ->
                                needs_recompile(Ex, OutDir, fun get_moduledefs/1)
                        end,
    FirstExs = lists:filter(RecompileFilterFn, FirstExsUnfiltered),
    RestExs = lists:filter(RecompileFilterFn, RestExsUnfiltered),

    ok = filelib:ensure_dir(OutDir),
    true = code:add_path(filename:absname(OutDir)),
    compile(FirstExs, ExOpts, OutDir),
    compile(RestExs, ExOpts, OutDir),
    
    true = code:set_path(OldCodePath),
    ok.

start_engine() ->
    App = application:load(elixir),
    {elixir_loaded, true} = {elixir_loaded, 
                             (App == ok orelse App == {error, {already_loaded, elixir}}) 
                             and (code:ensure_loaded(elixir) == {module, elixir})},
    application:start(elixir).
    
%% ===================================================================
%% Internal functions
%% ===================================================================

get_moduledefs(FileName) ->     
    {ok, MP} = re:compile("\\W*defmodule\\W+([a-zA-Z0-9]+)\\W+.*"),
    MatchHandler = fun ([Name], Acc) ->
                           [Name | Acc]
                   end,
    process_lines_in(FileName, MP, MatchHandler).
    
compile([], _, _) ->
    ok;
compile(Exs, ExOpts, OutDir) ->
    'Elixir-Code':compiler_options(orddict:from_list(ExOpts)),
    MsgFn = fun(F) -> 
                    io:format("Compiled ~s~n",[F])
            end,
    try 
        'Elixir-Kernel-ParallelCompiler':files_to_path(Exs, list_to_binary(OutDir), MsgFn),
        file:change_time(OutDir, erlang:localtime()),
        ok
    catch _:{'Elixir-CompileError',
             '__exception__',
             Reason,
             SourceFile, Line} ->
            rebar_log:log(error,"Compile error in ~s:~w~n ~ts~n~n",[SourceFile, Line, Reason]),
            throw({error, failed})
    end.

ex_opts(Config) ->
    orddict:from_list(rebar_config:get_local(Config, ex_opts, [{ignore_module_conflict, true}])).

%% I would love to be able to refactor the below into a separate module
%% Unfortunately rebar plugins currently have to be a single module
%% I've added some ideas on how to fix onto my nice-to-do pile, so we'll see

process_lines_in(FileName, MP, MatchHandler) ->
    {ok, File} = file:open(FileName, [read]),
    process_line(io:get_line(File, ""), File, MP, MatchHandler, []).

process_line(eof, File, _LineMatchPattern, _Handler, Acc) ->
    file:close(File),
    lists:reverse(Acc);

process_line(Line, File, LineMatchPattern, Handler, Acc) ->
     NextAcc = case re:run(Line, LineMatchPattern, [{capture, all_but_first, list}]) of
		   {match, Captures} -> Handler(Captures, Acc);
		   nomatch -> Acc
               end,
     process_line(io:get_line(File,""), File, LineMatchPattern, Handler, NextAcc).

gather_sources(FirstFiles, SrcDirs, MoreSources) ->
    Gathered = lists:foldl(fun gather_src/2, MoreSources, SrcDirs),
    RestExs  = [Source || Source <- Gathered, not lists:member(Source, FirstFiles)],
    {ok, FirstFiles, RestExs}.

needs_recompile(FileName, OutDir, ModuleListingFn) ->    
    ModuleNames = ModuleListingFn(FileName),
    SourceDate = filelib:last_modified(FileName),
    lists:foldl(
      fun
          (ModuleName, false) ->
              Beam = beampath(OutDir, ModuleName),
              is_beam_expired(Beam, SourceDate);
          (_ModuleName, true) -> true
      end,
      false,
      ModuleNames).

gather_src(Dir, Acc) ->
    Gathered = lists:map(fun list_to_binary/1, rebar_utils:find_files(Dir, ".*\\.ex\$")),
    Gathered ++ Acc.

-spec src_dirs(SrcDirs::[string()]) -> [file:filename(), ...].
src_dirs([]) ->
    ["src","lib"];
src_dirs(SrcDirs) ->
    SrcDirs.

-spec dirs(Dir::file:filename()) -> [file:filename()].
dirs(Dir) ->
    rebar_log:log(debug, "dirs called with ~p~n", [Dir]),
    [F || F <- filelib:wildcard(filename:join([Dir, "*"])), filelib:is_dir(F)].

-spec delete_dir(Dir::file:filename(),
                 Subdirs::[string()]) -> 'ok' | {'error', atom()}.
delete_dir(Dir, []) ->
    file:del_dir(Dir);
delete_dir(Dir, Subdirs) ->
    lists:foreach(fun(D) -> delete_dir(D, dirs(D)) end, Subdirs),
    file:del_dir(Dir).

%% Gets lib_dirs setting, if any, from Config, expands and adds
%% to code path 
fix_libdir_codepath(Config) ->
    OldLibPaths = code:get_path(),
    Paths = rebar_config:get_local(Config, lib_dirs, []),
    LibPaths = expand_lib_dirs(Paths, rebar_utils:get_cwd(), []),
    case code:add_pathsa(LibPaths) of 
        ok ->
            {ok, OldLibPaths};
        Err  -> Err
    end.

%% expand_lib_dirs is lifted from rebar_config.erl in rebar
expand_lib_dirs([], _Root, Acc) ->
    Acc;
expand_lib_dirs([Dir | Rest], Root, Acc) ->
    Apps = filelib:wildcard(filename:join([Dir, "*", "ebin"])),
    FqApps = [filename:join([Root, A]) || A <- Apps],
    expand_lib_dirs(Rest, Root, Acc ++ FqApps).

beampath(BeamDir, ModuleName) ->
    BeamFile = lists:flatten(["Elixir-", ModuleName, ".beam"]),
    filename:join(BeamDir, BeamFile).

is_beam_expired(BeamPath, SourceDate) ->
    BeamDate = filelib:last_modified(BeamPath),
    BeamDate =< SourceDate.
