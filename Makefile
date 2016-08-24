PROJECT = erlroute

TEST_ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +debug_info

ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror

dep_teaser = git https://github.com/spylik/teaser master

TEST_DEPS = teaser poolboy

ifeq ($(USER),travis)
    TEST_DEPS += covertool
	dep_covertool = git https://github.com/idubrov/covertool
endif

SHELL_DEPS = sync lager

SHELL_OPTS = -pa ebin/ test/ -env ERL_LIBS deps -eval 'lager:start(),mlibs:discover()' -run mlibs autotest_on_compile

include erlang.mk
