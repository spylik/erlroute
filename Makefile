PROJECT = erlroute

DEPS = teaser

dep_teaser = git https://github.com/spylik/teaser master

TEST_DEPS = poolboy

#ifeq ($(USER),travis)
    TEST_DEPS += coveralls-erl
    dep_coveralls-erl = git https://github.com/markusn/coveralls-erl master
#endif

SHELL_DEPS = sync lager

SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()' -run mlibs autotest_on_compile
#SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()'

include erlang.mk

sendcoverreport: 
	erl -noshell -pa ebin/ test/ -env ERL_LIBS deps -eval 'coveralls:convert_and_send_file("eunit.coverdata","$ENV{TRAVIS_JOB_ID}","travis-ci")'
