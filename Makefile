PROJECT = erlroute

# --------------------------------------------------------------------
# Support being sub-project
# --------------------------------------------------------------------

ifeq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
    DEPS_DIR ?= $(shell dirname $(CURDIR))
endif

# --------------------------------------------------------------------
# Defining OTP version for this project which uses by kerl
# --------------------------------------------------------------------

ifneq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
ERLANG_OTP = OTP-$(shell cat ./.env | grep ERLANG_VERSION | sed -e s/^ERLANG_VERSION=//)
endif

# our includes (must rid after refactoring, esp. erlpusher, erlroute)
OUR_INCS += $(DEPS_DIR)/teaser/include

TEST_ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_export_all +warn_unused_import +warn_untyped_record +warn_missing_spec_all -Werror +debug_info

#ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror

dep_teaser = git https://github.com/spylik/teaser develop

DEPS = parse_trans

TEST_DEPS = teaser poolboy
PLT_APPS = poolboy

ifeq ($(USER),travis)
	ERLC_OPTS += +warn_export_vars +warn_shadow_vars +warn_obsolete_guard +warn_missing_spec -Werror
    TEST_DEPS += covertool
	dep_covertool = git https://github.com/idubrov/covertool
endif

# --------------------------------------------------------------------
# Development enviroment ("make shell" to run it).
# --------------------------------------------------------------------

comma:= ,
empty:=
space:= $(empty) $(empty)

ERL_COMPILER_OPTIONS = [$(subst $(space),$(comma),$(addsuffix "}, $(addprefix {i$(comma)", $(OUR_INCS))))]
export ERL_COMPILER_OPTIONS

SHELL_DEPS = sync lager

SHELL_OPTS = -kernel shell_history enabled -pa ebin/ test/ -I -eval 'mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

include erlang.mk

app:: rebar.config
