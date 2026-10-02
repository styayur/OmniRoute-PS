BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-OmniRouteTestModules
}

Describe 'Canonical protocol normalization' {
    It 'normalizes OpenAI chat requests into IR' {
        $body = @{
            model = 'gpt-test'
            messages = @(@{ role = 'user'; content = 'hello' })
            tools = @(@{ type = 'function'; function = @{ name = 'lookup'; description = 'Lookup'; parameters = @{ type = 'object'; properties = @{ q = @{ type = 'string' } } } } })
            tool_choice = @{ type = 'function'; function = @{ name = 'lookup' } }
            stream = $false
            temperature = 0.2
        }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-chat'
        $ir.protocol | Should -Be 'openai-chat'
        $ir.messages[0].content[0].text | Should -Be 'hello'
        $ir.tools[0].name | Should -Be 'lookup'
        $ir.toolChoice.name | Should -Be 'lookup'
        $ir.generation.temperature | Should -Be 0.2
    }

    It 'normalizes Anthropic messages and tool results' {
        $body = @{
            model = 'claude-test'
            system = 'be concise'
            max_tokens = 64
            messages = @(
                @{ role = 'user'; content = @(@{ type = 'text'; text = 'weather?' }) }
                @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'tool_1'; name = 'weather'; input = @{ city = 'SG' } }) }
                @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tool_1'; content = 'sunny' }) }
            )
            tools = @(@{ name = 'weather'; description = 'Weather'; input_schema = @{ type = 'object' } })
        }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'anthropic-messages'
        $ir.system[0].text | Should -Be 'be concise'
        $ir.messages.Count | Should -Be 3
        $ir.messages[1].content[0].type | Should -Be 'tool_call'
        $ir.messages[2].content[0].type | Should -Be 'tool_result'
        $ir.tools[0].inputSchema.type | Should -Be 'object'
    }

    It 'normalizes Responses input and instructions' {
        $body = @{
            model = 'gpt-test'
            instructions = 'be brief'
            input = 'hello'
            max_output_tokens = 12
        }
        $ir = ConvertTo-OmniRouteCanonicalRequest -Body $body -Protocol 'openai-responses'
        $ir.system[0].text | Should -Be 'be brief'
        $ir.messages[0].content[0].text | Should -Be 'hello'
        $ir.generation.maxTokens | Should -Be 12
    }
}

Describe 'Cross-protocol tool mapping' {
    BeforeEach {
        $openAiRequest = @{
            model = 'gpt-test'
            messages = @(
                @{ role = 'user'; content = 'weather?' }
                @{ role = 'assistant'; tool_calls = @(@{ id = 'call_1'; type = 'function'; function = @{ name = 'weather'; arguments = '{"city":"SG"}' } }) }
                @{ role = 'tool'; tool_call_id = 'call_1'; content = 'sunny' }
            )
            tools = @(@{ type = 'function'; function = @{ name = 'weather'; description = 'Weather'; parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } } } } })
            tool_choice = 'auto'
        }
        $anthropicRequest = @{
            model = 'claude-test'
            max_tokens = 64
            messages = @(
                @{ role = 'user'; content = @(@{ type = 'text'; text = 'weather?' }) }
                @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'tool_1'; name = 'weather'; input = @{ city = 'SG' } }) }
                @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tool_1'; content = 'sunny' }) }
            )
            tools = @(@{ name = 'weather'; description = 'Weather'; input_schema = @{ type = 'object' } })
        }
        $openAiIr = ConvertTo-OmniRouteCanonicalRequest -Body $openAiRequest -Protocol 'openai-chat'
        $anthropicIr = ConvertTo-OmniRouteCanonicalRequest -Body $anthropicRequest -Protocol 'anthropic-messages'
        $anthropicProvider = @{ type = 'anthropic'; tools = $true }
        $geminiProvider = @{ type = 'gemini'; tools = $true }
        $openAiProvider = @{ type = 'openai'; tools = $true }
    }

    It 'maps OpenAI tools to Anthropic tool_use and tool_result blocks' {
        $out = ConvertFrom-OmniRouteCanonicalRequest -Request $openAiIr -Provider $anthropicProvider
        $out.tools[0].name | Should -Be 'weather'
        $out.messages[1].content[0].type | Should -Be 'tool_use'
        $out.messages[2].content[0].type | Should -Be 'tool_result'
        $out.messages[2].content[0].tool_use_id | Should -Be 'call_1'
    }

    It 'maps OpenAI tools to Gemini functionCall and functionResponse' {
        $out = ConvertFrom-OmniRouteCanonicalRequest -Request $openAiIr -Provider $geminiProvider
        $out.tools[0].functionDeclarations[0].name | Should -Be 'weather'
        $json = $out.contents | ConvertTo-Json -Depth 20 -Compress
        $json | Should -Match 'functionCall'
        $json | Should -Match 'functionResponse'
    }

    It 'maps Anthropic tools to OpenAI function calls and results' {
        $out = ConvertFrom-OmniRouteCanonicalRequest -Request $anthropicIr -Provider $openAiProvider
        $out.tools[0].function.name | Should -Be 'weather'
        $out.messages[1].tool_calls[0].function.name | Should -Be 'weather'
        $out.messages[2].role | Should -Be 'tool'
        $out.messages[2].tool_call_id | Should -Be 'tool_1'
    }

    It 'maps Anthropic tools to Gemini declarations and calls' {
        $out = ConvertFrom-OmniRouteCanonicalRequest -Request $anthropicIr -Provider $geminiProvider
        $out.tools[0].functionDeclarations[0].name | Should -Be 'weather'
        ($out.contents | ConvertTo-Json -Depth 20 -Compress) | Should -Match 'functionCall'
        ($out.contents | ConvertTo-Json -Depth 20 -Compress) | Should -Match 'functionResponse'
    }

    It 'round-trips an OpenAI tool result through Anthropic canonical IR' {
        $anthropic = ConvertFrom-OmniRouteCanonicalRequest -Request $openAiIr -Provider $anthropicProvider
        $canonical = ConvertTo-OmniRouteCanonicalRequest -Body @{ model = 'claude-test'; max_tokens = 64; messages = $anthropic.messages; tools = @(@{ name = 'weather'; description = 'Weather'; input_schema = @{ type = 'object' } }) } -Protocol 'anthropic-messages'
        $roundTrip = ConvertFrom-OmniRouteCanonicalRequest -Request $canonical -Provider $openAiProvider
        $roundTrip.messages[2].role | Should -Be 'tool'
        $roundTrip.messages[2].tool_call_id | Should -Be 'call_1'
        $roundTrip.messages[2].content | Should -Be 'sunny'
    }
}

Describe 'Canonical response rendering' {
    It 'renders a canonical response as Anthropic Messages' {
        $response = @{ id = 'msg_1'; model = 'claude-test'; content = @(@{ type = 'text'; text = 'hello' }); toolCalls = @(); finishReason = 'end_turn'; usage = @{ input_tokens = 1; output_tokens = 2 } }
        $out = ConvertFrom-OmniRouteCanonicalResponse -Response $response -Protocol 'anthropic-messages'
        $out.type | Should -Be 'message'
        $out.content[0].text | Should -Be 'hello'
        $out.stop_reason | Should -Be 'end_turn'
        $out.usage.output_tokens | Should -Be 2
    }

    It 'renders a canonical tool call as an Anthropic tool_use block' {
        $response = @{ id = 'msg_1'; model = 'claude-test'; content = @(); toolCalls = @(@{ id = 'tool_1'; name = 'weather'; arguments = @{ city = 'SG' } }); finishReason = 'tool_calls'; usage = @{ input_tokens = 1; output_tokens = 1 } }
        $out = ConvertFrom-OmniRouteCanonicalResponse -Response $response -Protocol 'anthropic-messages'
        $out.content[0].type | Should -Be 'tool_use'
        $out.stop_reason | Should -Be 'tool_use'
    }
}
