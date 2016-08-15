PROJECT = erlroute

dep_teaser = git https://github.com/spylik/teaser master

TEST_DEPS = teaser poolboy

ifeq ($(USER),travis)
    TEST_DEPS += coveralls-erl
    dep_coveralls-erl = git https://github.com/markusn/coveralls-erl master
endif

SHELL_DEPS = sync lager

SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()' -run mlibs autotest_on_compile
#SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()'

include erlang.mk

sendcoverreport: 
	erl -noshell -pa ebin/ test/ -env ERL_LIBS deps -eval '{ok, Dir} = file:get_cwd(), {ok, Listing} = file:list_dir(Dir), io:format("files is ~p",[Listing]), JobId = unicode:characters_to_binary(os:getenv("TRAVIS_JOB_ID")), io:format("job is ~p",[JobId]), coveralls:convert_and_send_file("eunit.coverdata",os:getenv("TRAVIS_JOB_ID"),"travis-ci")'
