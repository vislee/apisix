#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use t::APISIX 'no_plan';

log_level("info");
repeat_each(1);
no_long_string();
no_root_location();


my $resp_file = 't/assets/ai-proxy-stream-response.json';
open(my $fh, '<', $resp_file) or die "Could not open file '$resp_file' $!";
my $resp = do { local $/; <$fh> };
close($fh);

print "Hello, World!\n";
print $resp;


add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    my $http_config = $block->http_config // <<_EOC_;
        server {
            server_name openai;
            listen 6724;

            default_type 'application/json';

            location /v1/chat/completions {
                content_by_lua_block {
                    local json = require("cjson.safe")

                    if ngx.req.get_method() ~= "POST" then
                        ngx.status = 400
                        ngx.say("Unsupported request method: ", ngx.req.get_method())
                    end
                    ngx.req.read_body()
                    local body, err = ngx.req.get_body_data()
                    body, err = json.decode(body)

                    local query_auth = ngx.req.get_uri_args()["api_key"]

                    if query_auth ~= "apikey" then
                        ngx.status = 401
                        ngx.say("Unauthorized")
                        return
                    end

                    local data, err = json.decode([[$resp]])
                    if not err then
                        ngx.status = 500
                        ngx.say(err)
                        return
                    end

                    ngx.status = 200
                    for _, val in ipairs(data) do
                        ngx.say(val)
                        ngx.flush(true)
                    end
                    return
                }
            }
        }
_EOC_

    $block->set_value("http_config", $http_config);
});

run_tests();

__DATA__

=== TEST 1: send request
--- log_config
local api_ctx = ngx.ctx.api_ctx
if api_ctx then
    ngx.log(ngx.INFO, "prompt_tokens: ", api_ctx.ai_token_usage and api_ctx.ai_token_usage.prompt_tokens or 0)
    ngx.log(ngx.INFO, "completion_tokens: ", api_ctx.ai_token_usage and api_ctx.ai_token_usage.completion_tokens or 0)
    ngx.log(ngx.INFO, "total_tokens: ", api_ctx.ai_token_usage and api_ctx.ai_token_usage.total_tokens or 0)
end

--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/anything",
                    "plugins": {
                        "ai-proxy": {
                            "provider": "openai",
                            "auth": {
                                "header": {
                                    "Authorization": "Bearer token"
                                }
                            },
                            "options": {
                                "model": "gpt-35-turbo-instruct",
                                "max_tokens": 1024,
                                "temperature": 1.0
                            },
                            "override": {
                                "endpoint": "http://localhost:6724"
                            },
                            "ssl_verify": false
                        }
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }

--- request
POST /anything
{ "messages": [ { "role": "system", "content": "You are a mathematician" }, { "role": "user", "content": "What is 1+1?"} ] }
--- error_code: 200
--- no_error_log
[error]
--- error_log
prompt_tokens: 19
completion_tokens: 13
total_tokens: 32
