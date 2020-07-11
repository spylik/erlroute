PROJECT = erlroute

# --------------------------------------------------------------------
# Defining OTP version for this project which uses by kerl
# --------------------------------------------------------------------

ERLANG_OTP = OTP-22.3


TEST_ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +debug_info

#ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror

dep_teaser = git https://github.com/spylik/teaser master

DEPS = parse_trans

TEST_DEPS = teaser poolboy

ifeq ($(USER),travis)
	ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror
    TEST_DEPS += covertool
	dep_covertool = git https://github.com/idubrov/covertool
endif

SHELL_DEPS = sync lager

SHELL_OPTS = -kernel shell_history enabled -pa ebin/ test/ -I -eval 'mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

include erlang.mk
