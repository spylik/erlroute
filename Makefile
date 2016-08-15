PROJECT = erlroute

DEPS = teaser

dep_teaser = git https://github.com/spylik/teaser master

TEST_DEPS = poolboy

ifeq ($(USER),travis)
    TEST_DEPS += ecoveralls
    dep_ecoveralls = git https://github.com/nifoc/ecoveralls master
endif

SHELL_DEPS = sync lager

SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()' -run mlibs autotest_on_compile
#SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'code:ensure_loaded(erlroute_app),code:ensure_loaded(erlroute_tests),lager:start()'

include erlang.mk

coverage-report: $(shell ls -1rt `find logs -type f -name \*.coverdata 2>/dev/null` | tail -n1)
    $(gen_verbose) erl -noshell -pa ebin deps/*/ebin -eval 'ecoveralls:travis_ci("$?"), init:stop()'

.PHONY: coverage-report
