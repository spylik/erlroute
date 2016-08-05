PROJECT = erlroute

DEPS = teaser

dep_teaser = git https://github.com/spylik/teaser master

TEST_DEPS = poolboy

SHELL_DEPS = sync

SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -run mlibs autotest_on_compile

include erlang.mk
