PROJECT = erlroute

DEPS = teaser

dep_teaser = git https://github.com/spylik/teaser master

TEST_DEPS = poolboy

SHELL_DEPS = sync lager

#SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()' -run mlibs autotest_on_compile
SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()'

include erlang.mk
