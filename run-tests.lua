#!/usr/bin/env lua
-- Run the whole suite:  lua run-tests.lua

package.path = "./lib/?.lua;./sim/?.lua;./?.lua;" .. package.path

local T = require("test.init")

require("test.wire_test")
require("test.transport_test")

T.report()
