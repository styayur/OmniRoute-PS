Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-OmniRouteProtocolError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    throw "Unsupported parameter: $Message"
}

function Get-OmniRouteTextFromContent {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [string]) { return $Content }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in @($Content)) {
        if ($part -is [string]) { $parts.Add($part); continue }
        if ($part -is [System.Collections.IDictionary]) {
            $text = Get-OmniRouteDictValue -Dictionary $part -Name 'text' -Default $null
            if ($null -ne $text) { $parts.Add([string]$text); continue }
            $content = Get-OmniRouteDictValue -Dictionary $part -Name 'content' -Default $null
            if ($null -ne $content) { $parts.Add([string]$content) }
        }
    }
    return ($parts -join "`n")
}

function ConvertTo-OmniRouteCanonicalContentPart {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Part,
        [ValidateSet('openai', 'anthropic', 'responses')][string]$Source = 'openai'
    )
    if ($null -eq $Part) { return $null }
    if ($Part -is [string]) { return @{ type = 'text'; text = $Part } }
    if ($Part -isnot [System.Collections.IDictionary]) { return @{ type = 'text'; text = [string]$Part } }
    $type = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'type' -Default '')

    if ($Source -eq 'anthropic') {
        switch ($type) {
            'text' { return @{ type = 'text'; text = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'text' -Default '') } }
            'image' { return @{ type = 'image'; source = (Get-OmniRouteDictValue -Dictionary $Part -Name 'source' -Default @{}) } }
            'tool_use' { return @{ type = 'tool_call'; id = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'id' -Default ('tool_' + [guid]::NewGuid().ToString('N'))); name = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'name' -Default ''); arguments = (Get-OmniRouteDictValue -Dictionary $Part -Name 'input' -Default @{}) } }
            'tool_result' { return @{ type = 'tool_result'; toolCallId = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'tool_use_id' -Default ''); content = (Get-OmniRouteDictValue -Dictionary $Part -Name 'content' -Default ''); isError = [bool](Get-OmniRouteDictValue -Dictionary $Part -Name 'is_error' -Default $false) } }
            default { Stop-OmniRouteProtocolError -Message "Anthropic content block type '$type' is not supported." }
        }
    }

    if ($Source -eq 'responses') {
        switch ($type) {
            { $_ -in @('input_text', 'output_text', 'text') } { return @{ type = 'text'; text = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'text' -Default '') } }
            'input_image' { return @{ type = 'image'; source = (Get-OmniRouteDictValue -Dictionary $Part -Name 'image_url' -Default (Get-OmniRouteDictValue -Dictionary $Part -Name 'url' -Default '')) } }
            default { Stop-OmniRouteProtocolError -Message "Responses content part '$type' is not supported." }
        }
    }

    switch ($type) {
        { $_ -in @('text', 'input_text', 'output_text') } { return @{ type = 'text'; text = [string](Get-OmniRouteDictValue -Dictionary $Part -Name 'text' -Default '') } }
        'image_url' {
            $image = Get-OmniRouteDictValue -Dictionary $Part -Name 'image_url' -Default @{}
            $source = if ($image -is [System.Collections.IDictionary]) { Get-OmniRouteDictValue -Dictionary $image -Name 'url' -Default '' } else { [string]$image }
            return @{ type = 'image'; source = $source }
        }
        default {
            if ([string]::IsNullOrWhiteSpace($type)) { return @{ type = 'text'; text = [string]$Part } }
            Stop-OmniRouteProtocolError -Message "OpenAI content part '$type' is not supported."
        }
    }
}

function ConvertTo-OmniRouteCanonicalMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Message,
        [ValidateSet('openai', 'anthropic', 'responses')][string]$Source = 'openai'
    )
    $role = [string](Get-OmniRouteDictValue -Dictionary $Message -Name 'role' -Default 'user')
    $content = [System.Collections.Generic.List[object]]::new()
    $rawContent = Get-OmniRouteDictValue -Dictionary $Message -Name 'content' -Default ''
    if ($rawContent -is [string]) {
        if ($rawContent -ne '' -or @(Get-OmniRouteDictValue -Dictionary $Message -Name 'tool_calls' -Default @()).Count -eq 0) { $content.Add(@{ type = 'text'; text = $rawContent }) }
    }
    else {
        foreach ($part in @($rawContent)) {
            $converted = ConvertTo-OmniRouteCanonicalContentPart -Part $part -Source $Source
            if ($null -ne $converted) { $content.Add($converted) }
        }
    }
    if ($Source -eq 'openai' -and $role -eq 'tool') {
        $content.Clear()
        $content.Add(@{ type = 'tool_result'; toolCallId = [string](Get-OmniRouteDictValue -Dictionary $Message -Name 'tool_call_id' -Default ''); content = [string](Get-OmniRouteDictValue -Dictionary $Message -Name 'content' -Default ''); isError = $false })
    }
    if ($Source -eq 'openai') {
        foreach ($toolCall in @(Get-OmniRouteDictValue -Dictionary $Message -Name 'tool_calls' -Default @())) {
            $function = Get-OmniRouteDictValue -Dictionary $toolCall -Name 'function' -Default @{}
            $arguments = Get-OmniRouteDictValue -Dictionary $function -Name 'arguments' -Default '{}'
            try { $arguments = $arguments | ConvertFrom-Json -AsHashtable } catch { }
            $content.Add(@{ type = 'tool_call'; id = [string](Get-OmniRouteDictValue -Dictionary $toolCall -Name 'id' -Default ('tool_' + [guid]::NewGuid().ToString('N'))); name = [string](Get-OmniRouteDictValue -Dictionary $function -Name 'name' -Default ''); arguments = $arguments })
        }
    }
    return @{ role = $role; content = @($content); toolCalls = @($content | Where-Object { $_.type -eq 'tool_call' }); toolResult = @($content | Where-Object { $_.type -eq 'tool_result' } | Select-Object -First 1) }
}

function ConvertTo-OmniRouteCanonicalTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Tool,
        [ValidateSet('openai', 'anthropic', 'responses')][string]$Source = 'openai'
    )
    $name = ''
    $description = ''
    $inputSchema = @{}
    if ($Source -eq 'anthropic') {
        $name = [string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'name' -Default '')
        $description = [string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'description' -Default '')
        $inputSchema = Get-OmniRouteDictValue -Dictionary $Tool -Name 'input_schema' -Default @{}
    }
    elseif ($Source -eq 'responses') {
        if ([string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'type' -Default '') -ne 'function') {
            Stop-OmniRouteProtocolError -Message "Responses tool type '$([string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'type' -Default ''))' is not supported."
        }
        $name = [string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'name' -Default '')
        $description = [string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'description' -Default '')
        $inputSchema = Get-OmniRouteDictValue -Dictionary $Tool -Name 'parameters' -Default @{}
    }
    else {
        if ([string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'type' -Default 'function') -ne 'function') {
            Stop-OmniRouteProtocolError -Message "OpenAI tool type '$([string](Get-OmniRouteDictValue -Dictionary $Tool -Name 'type' -Default ''))' is not supported."
        }
        $function = Get-OmniRouteDictValue -Dictionary $Tool -Name 'function' -Default $Tool
        $name = [string](Get-OmniRouteDictValue -Dictionary $function -Name 'name' -Default '')
        $description = [string](Get-OmniRouteDictValue -Dictionary $function -Name 'description' -Default '')
        $inputSchema = Get-OmniRouteDictValue -Dictionary $function -Name 'parameters' -Default @{}
    }
    if ([string]::IsNullOrWhiteSpace($name)) { Stop-OmniRouteProtocolError -Message 'Tool name cannot be empty.' }
    return @{ name = $name; description = $description; inputSchema = $inputSchema }
}

function ConvertTo-OmniRouteCanonicalToolChoice {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ToolChoice,
        [ValidateSet('openai', 'anthropic', 'responses')][string]$Source = 'openai'
    )
    if ($null -eq $ToolChoice) { return $null }
    if ($ToolChoice -is [string]) { return [string]$ToolChoice }
    if ($ToolChoice -isnot [System.Collections.IDictionary]) { return [string]$ToolChoice }
    if ($Source -eq 'openai') {
        $function = Get-OmniRouteDictValue -Dictionary $ToolChoice -Name 'function' -Default @{}
        $name = Get-OmniRouteDictValue -Dictionary $function -Name 'name' -Default $null
        if ($null -ne $name) { return @{ type = 'tool'; name = [string]$name } }
    }
    if ($Source -eq 'responses') {
        $name = Get-OmniRouteDictValue -Dictionary $ToolChoice -Name 'name' -Default $null
        if ($null -ne $name) { return @{ type = 'tool'; name = [string]$name } }
    }
    if ($Source -eq 'anthropic') {
        $type = [string](Get-OmniRouteDictValue -Dictionary $ToolChoice -Name 'type' -Default '')
        if ($type -eq 'tool') { return @{ type = 'tool'; name = [string](Get-OmniRouteDictValue -Dictionary $ToolChoice -Name 'name' -Default '') } }
        return $type
    }
    return [string](Get-OmniRouteDictValue -Dictionary $ToolChoice -Name 'type' -Default 'auto')
}

function ConvertTo-OmniRouteCanonicalRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Body,
        [Parameter(Mandatory)][ValidateSet('openai-chat', 'openai-responses', 'anthropic-messages')][string]$Protocol
    )
    $supported = switch ($Protocol) {
        'openai-chat' { @('model', 'messages', 'tools', 'tool_choice', 'stream', 'temperature', 'top_p', 'max_tokens', 'max_completion_tokens', 'stop', 'metadata', 'user', 'seed', 'response_format', 'reasoning_effort') }
        'openai-responses' { @('model', 'input', 'instructions', 'tools', 'tool_choice', 'stream', 'temperature', 'top_p', 'max_output_tokens', 'stop', 'metadata', 'user', 'seed') }
        'anthropic-messages' { @('model', 'messages', 'system', 'max_tokens', 'temperature', 'top_p', 'stop_sequences', 'stream', 'tools', 'tool_choice', 'metadata') }
    }
    foreach ($key in $Body.Keys) {
        if ($key -notin $supported) { Stop-OmniRouteProtocolError -Message "'$key' is not supported for protocol '$Protocol'." }
    }
    if (-not $Body.Contains('model') -or [string]::IsNullOrWhiteSpace([string]$Body.model)) { throw "Invalid request: 'model' is required." }

    $messages = [System.Collections.Generic.List[object]]::new()
    $systemContent = [System.Collections.Generic.List[object]]::new()
    $source = if ($Protocol -eq 'openai-responses') { 'responses' } elseif ($Protocol -eq 'anthropic-messages') { 'anthropic' } else { 'openai' }

    if ($Protocol -eq 'openai-responses') {
        if ($Body.Contains('instructions') -and -not [string]::IsNullOrWhiteSpace([string]$Body.instructions)) { $systemContent.Add(@{ type = 'text'; text = [string]$Body.instructions }) }
        $inputValue = Get-OmniRouteDictValue -Dictionary $Body -Name 'input' -Default $null
        if ($null -ne $inputValue) {
            if ($inputValue -is [string]) { $messages.Add((ConvertTo-OmniRouteCanonicalMessage -Message @{ role = 'user'; content = $inputValue } -Source 'responses')) }
            else {
                foreach ($item in @($inputValue)) {
                    if ($item -is [string]) { $messages.Add((ConvertTo-OmniRouteCanonicalMessage -Message @{ role = 'user'; content = $item } -Source 'responses')) }
                    elseif ($item -is [System.Collections.IDictionary]) { $messages.Add((ConvertTo-OmniRouteCanonicalMessage -Message $item -Source 'responses')) }
                    else { Stop-OmniRouteProtocolError -Message 'Responses input items must be strings or objects.' }
                }
            }
        }
    }
    elseif ($Protocol -eq 'anthropic-messages') {
        $systemRaw = Get-OmniRouteDictValue -Dictionary $Body -Name 'system' -Default $null
        if ($null -ne $systemRaw) {
            if ($systemRaw -is [string]) { $systemContent.Add(@{ type = 'text'; text = $systemRaw }) }
            else {
                foreach ($part in @($systemRaw)) {
                    $converted = ConvertTo-OmniRouteCanonicalContentPart -Part $part -Source 'anthropic'
                    if ($null -ne $converted) { $systemContent.Add($converted) }
                }
            }
        }
        foreach ($message in @(Get-OmniRouteDictValue -Dictionary $Body -Name 'messages' -Default @())) { $messages.Add((ConvertTo-OmniRouteCanonicalMessage -Message $message -Source 'anthropic')) }
    }
    else {
        foreach ($message in @(Get-OmniRouteDictValue -Dictionary $Body -Name 'messages' -Default @())) {
            $role = [string](Get-OmniRouteDictValue -Dictionary $message -Name 'role' -Default 'user')
            if ($role -in @('system', 'developer')) {
                $systemContent.Add(@{ type = 'text'; text = (Get-OmniRouteTextFromContent -Content (Get-OmniRouteDictValue -Dictionary $message -Name 'content' -Default '')) })
                continue
            }
            $messages.Add((ConvertTo-OmniRouteCanonicalMessage -Message $message -Source 'openai'))
        }
    }

    $tools = [System.Collections.Generic.List[object]]::new()
    foreach ($tool in @(Get-OmniRouteDictValue -Dictionary $Body -Name 'tools' -Default @())) { $tools.Add((ConvertTo-OmniRouteCanonicalTool -Tool $tool -Source $source)) }

    $maxTokens = Get-OmniRouteDictValue -Dictionary $Body -Name 'max_tokens' -Default $null
    if ($null -eq $maxTokens) { $maxTokens = Get-OmniRouteDictValue -Dictionary $Body -Name 'max_completion_tokens' -Default $null }
    if ($null -eq $maxTokens) { $maxTokens = Get-OmniRouteDictValue -Dictionary $Body -Name 'max_output_tokens' -Default $null }

    return @{
        protocol   = $Protocol
        model      = [string]$Body.model
        messages   = @($messages)
        system     = @($systemContent)
        tools      = @($tools)
        toolChoice = ConvertTo-OmniRouteCanonicalToolChoice -ToolChoice (Get-OmniRouteDictValue -Dictionary $Body -Name 'tool_choice' -Default $null) -Source $source
        stream     = [bool](Get-OmniRouteDictValue -Dictionary $Body -Name 'stream' -Default $false)
        generation = @{ temperature = Get-OmniRouteDictValue -Dictionary $Body -Name 'temperature' -Default $null; topP = Get-OmniRouteDictValue -Dictionary $Body -Name 'top_p' -Default $null; maxTokens = $maxTokens; stop = @(Get-OmniRouteDictValue -Dictionary $Body -Name 'stop' -Default (Get-OmniRouteDictValue -Dictionary $Body -Name 'stop_sequences' -Default @())) }
        metadata   = Get-OmniRouteDictValue -Dictionary $Body -Name 'metadata' -Default @{}
    }
}

function ConvertFrom-OmniRouteCanonicalRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Request,
        [Parameter(Mandatory)][hashtable]$Provider
    )
    $type = [string]$Provider.type
    $body = [ordered]@{ model = [string]$Request.model }

    if ($type -in @('openai', 'custom-openai', 'ollama')) {
        $messages = [System.Collections.Generic.List[object]]::new()
        foreach ($system in @($Request.system)) { $messages.Add(@{ role = 'system'; content = (Get-OmniRouteTextFromContent -Content $system) }) }
        foreach ($message in @($Request.messages)) {
            $parts = [System.Collections.Generic.List[object]]::new()
            $toolCalls = [System.Collections.Generic.List[object]]::new()
            foreach ($part in @($message.content)) {
                switch ([string]$part.type) {
                    'text' { $parts.Add(@{ type = 'text'; text = [string]$part.text }) }
                    'image' { $parts.Add(@{ type = 'image_url'; image_url = @{ url = if ($part.source -is [System.Collections.IDictionary]) { [string](Get-OmniRouteDictValue -Dictionary $part.source -Name 'url' -Default '') } else { [string]$part.source } } }) }
                    'tool_call' { $toolCalls.Add(@{ id = [string]$part.id; type = 'function'; function = @{ name = [string]$part.name; arguments = ($part.arguments | ConvertTo-Json -Depth 20 -Compress) } }) }
                    'tool_result' { $messages.Add(@{ role = 'tool'; tool_call_id = [string]$part.toolCallId; content = (Get-OmniRouteTextFromContent -Content $part.content) }) }
                    default { Stop-OmniRouteProtocolError -Message "Canonical content part '$($part.type)' cannot be mapped to OpenAI." }
                }
            }
            if ($parts.Count -eq 0 -and $toolCalls.Count -eq 0) { continue }
            $messageBody = @{ role = [string]$message.role; content = if ($parts.Count -eq 0) { $null } else { @($parts) } }
            if ($toolCalls.Count -gt 0) { $messageBody.tool_calls = @($toolCalls) }
            $messages.Add($messageBody)
        }
        $body.messages = @($messages)
        $body.stream = [bool]$Request.stream
        if ($Request.tools.Count -gt 0) {
            $body.tools = @($Request.tools | ForEach-Object { @{ type = 'function'; function = @{ name = $_.name; description = $_.description; parameters = $_.inputSchema } } })
            if ($null -ne $Request.toolChoice) {
                if ($Request.toolChoice -is [System.Collections.IDictionary] -and $Request.toolChoice.type -eq 'tool') { $body.tool_choice = @{ type = 'function'; function = @{ name = $Request.toolChoice.name } } }
                else { $body.tool_choice = $Request.toolChoice }
            }
        }
    }
    elseif ($type -eq 'anthropic') {
        $messages = [System.Collections.Generic.List[object]]::new()
        foreach ($message in @($Request.messages)) {
            $blocks = [System.Collections.Generic.List[object]]::new()
            foreach ($part in @($message.content)) {
                switch ([string]$part.type) {
                    'text' { $blocks.Add(@{ type = 'text'; text = [string]$part.text }) }
                    'image' { $blocks.Add(@{ type = 'image'; source = if ($part.source -is [System.Collections.IDictionary]) { $part.source } else { @{ type = 'url'; url = [string]$part.source } } }) }
                    'tool_call' { $blocks.Add(@{ type = 'tool_use'; id = [string]$part.id; name = [string]$part.name; input = $part.arguments }) }
                    'tool_result' { $blocks.Add(@{ type = 'tool_result'; tool_use_id = [string]$part.toolCallId; content = (Get-OmniRouteTextFromContent -Content $part.content); is_error = [bool]$part.isError }) }
                    default { Stop-OmniRouteProtocolError -Message "Canonical content part '$($part.type)' cannot be mapped to Anthropic." }
                }
            }
            $messages.Add(@{ role = [string]$message.role; content = @($blocks) })
        }
        $body.messages = @($messages)
        if (@($Request.system).Count -gt 0) { $body.system = Get-OmniRouteTextFromContent -Content $Request.system }
        $body.max_tokens = if ($null -eq $Request.generation.maxTokens) { 4096 } else { [int]$Request.generation.maxTokens }
        $body.stream = [bool]$Request.stream
        if ($Request.tools.Count -gt 0) {
            $body.tools = @($Request.tools | ForEach-Object { @{ name = $_.name; description = $_.description; input_schema = $_.inputSchema } })
            if ($null -ne $Request.toolChoice) {
                if ($Request.toolChoice -is [System.Collections.IDictionary] -and $Request.toolChoice.type -eq 'tool') { $body.tool_choice = @{ type = 'tool'; name = $Request.toolChoice.name } }
                else { $body.tool_choice = @{ type = [string]$Request.toolChoice } }
            }
        }
    }
    elseif ($type -eq 'gemini') {
        $contents = [System.Collections.Generic.List[object]]::new()
        $functionResponses = [System.Collections.Generic.Dictionary[string,string]]::new()
        foreach ($message in @($Request.messages)) {
            $parts = [System.Collections.Generic.List[object]]::new()
            foreach ($part in @($message.content)) {
                switch ([string]$part.type) {
                    'text' { $parts.Add(@{ text = [string]$part.text }) }
                    'image' { $parts.Add(@{ inlineData = @{ mimeType = 'image/*'; data = [string]$part.source } }) }
                    'tool_call' { $parts.Add(@{ functionCall = @{ name = [string]$part.name; args = $part.arguments } }); $functionResponses[[string]$part.id] = [string]$part.name }
                    'tool_result' { $parts.Add(@{ functionResponse = @{ name = if ($functionResponses.ContainsKey([string]$part.toolCallId)) { $functionResponses[[string]$part.toolCallId] } else { [string]$part.toolCallId }; response = @{ result = (Get-OmniRouteTextFromContent -Content $part.content) } } }) }
                    default { Stop-OmniRouteProtocolError -Message "Canonical content part '$($part.type)' cannot be mapped to Gemini." }
                }
            }
            $role = if ($message.role -eq 'assistant') { 'model' } else { 'user' }
            $contents.Add(@{ role = $role; parts = @($parts) })
        }
        $body.contents = @($contents)
        if (@($Request.system).Count -gt 0) { $body.systemInstruction = @{ parts = @(@{ text = (Get-OmniRouteTextFromContent -Content $Request.system) }) } }
        if ($Request.tools.Count -gt 0) {
            $body.tools = @(@{ functionDeclarations = @($Request.tools | ForEach-Object { @{ name = $_.name; description = $_.description; parameters = $_.inputSchema } }) })
            if ($null -ne $Request.toolChoice) {
                $mode = if ($Request.toolChoice -is [System.Collections.IDictionary] -and $Request.toolChoice.type -eq 'tool') { 'ANY' } elseif ([string]$Request.toolChoice -eq 'none') { 'NONE' } else { 'AUTO' }
                $body.toolConfig = @{ functionCallingConfig = @{ mode = $mode } }
            }
        }
        $generationConfig = [ordered]@{}
        if ($null -ne $Request.generation.temperature) { $generationConfig.temperature = $Request.generation.temperature }
        if ($null -ne $Request.generation.topP) { $generationConfig.topP = $Request.generation.topP }
        if ($null -ne $Request.generation.maxTokens) { $generationConfig.maxOutputTokens = $Request.generation.maxTokens }
        if (@($Request.generation.stop).Count -gt 0) { $generationConfig.stopSequences = @($Request.generation.stop) }
        if ($generationConfig.Count -gt 0) { $body.generationConfig = $generationConfig }
    }
    else { throw "Unsupported provider type '$type'." }
    return $body
}

function ConvertTo-OmniRouteCanonicalResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Model
    )
    try { $response = $Content | ConvertFrom-Json -AsHashtable } catch { throw "Malformed upstream JSON: $($_.Exception.Message)" }
    if ($response -isnot [System.Collections.IDictionary]) { throw 'Malformed upstream JSON: expected an object.' }
    if ($response.Contains('error') -and $null -ne $response['error']) { throw "Upstream returned an error object: $($response['error'] | ConvertTo-Json -Compress -Depth 10)" }

    $contentParts = [System.Collections.Generic.List[object]]::new()
    $toolCalls = [System.Collections.Generic.List[object]]::new()
    $finishReason = 'stop'
    $usage = @{ input_tokens = 0; output_tokens = 0 }
    $id = [string](Get-OmniRouteDictValue -Dictionary $response -Name 'id' -Default ('msg_' + [guid]::NewGuid().ToString('N')))

    if ($Provider.type -in @('openai', 'custom-openai', 'ollama')) {
        $choices = @(Get-OmniRouteDictValue -Dictionary $response -Name 'choices' -Default @())
        if ($choices.Count -gt 0) {
            $message = Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'message' -Default @{}
            $text = Get-OmniRouteDictValue -Dictionary $message -Name 'content' -Default ''
            if ($null -ne $text -and [string]$text -ne '') { $contentParts.Add(@{ type = 'text'; text = [string]$text }) }
            foreach ($call in @(Get-OmniRouteDictValue -Dictionary $message -Name 'tool_calls' -Default @())) {
                $function = Get-OmniRouteDictValue -Dictionary $call -Name 'function' -Default @{}
                $arguments = Get-OmniRouteDictValue -Dictionary $function -Name 'arguments' -Default '{}'
                try { $arguments = $arguments | ConvertFrom-Json -AsHashtable } catch { }
                $toolCalls.Add(@{ id = [string](Get-OmniRouteDictValue -Dictionary $call -Name 'id' -Default ('tool_' + [guid]::NewGuid().ToString('N'))); name = [string](Get-OmniRouteDictValue -Dictionary $function -Name 'name' -Default ''); arguments = $arguments })
            }
            $finishReason = [string](Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'finish_reason' -Default 'stop')
        }
        $rawUsage = Get-OmniRouteDictValue -Dictionary $response -Name 'usage' -Default @{}
        $usage.input_tokens = [int](Get-OmniRouteDictValue -Dictionary $rawUsage -Name 'prompt_tokens' -Default 0)
        $usage.output_tokens = [int](Get-OmniRouteDictValue -Dictionary $rawUsage -Name 'completion_tokens' -Default 0)
    }
    elseif ($Provider.type -eq 'anthropic') {
        foreach ($part in @(Get-OmniRouteDictValue -Dictionary $response -Name 'content' -Default @())) {
            $partType = [string](Get-OmniRouteDictValue -Dictionary $part -Name 'type' -Default '')
            if ($partType -eq 'text') { $contentParts.Add(@{ type = 'text'; text = [string](Get-OmniRouteDictValue -Dictionary $part -Name 'text' -Default '') }) }
            elseif ($partType -eq 'tool_use') { $toolCalls.Add(@{ id = [string](Get-OmniRouteDictValue -Dictionary $part -Name 'id' -Default ('tool_' + [guid]::NewGuid().ToString('N'))); name = [string](Get-OmniRouteDictValue -Dictionary $part -Name 'name' -Default ''); arguments = (Get-OmniRouteDictValue -Dictionary $part -Name 'input' -Default @{}) }) }
        }
        $finishReason = [string](Get-OmniRouteDictValue -Dictionary $response -Name 'stop_reason' -Default 'end_turn')
        $rawUsage = Get-OmniRouteDictValue -Dictionary $response -Name 'usage' -Default @{}
        $usage.input_tokens = [int](Get-OmniRouteDictValue -Dictionary $rawUsage -Name 'input_tokens' -Default 0)
        $usage.output_tokens = [int](Get-OmniRouteDictValue -Dictionary $rawUsage -Name 'output_tokens' -Default 0)
    }
    elseif ($Provider.type -eq 'gemini') {
        foreach ($candidate in @(Get-OmniRouteDictValue -Dictionary $response -Name 'candidates' -Default @())) {
            $content = Get-OmniRouteDictValue -Dictionary $candidate -Name 'content' -Default @{}
            foreach ($part in @(Get-OmniRouteDictValue -Dictionary $content -Name 'parts' -Default @())) {
                if ($part.Contains('text')) { $contentParts.Add(@{ type = 'text'; text = [string]$part.text }) }
                if ($part.Contains('functionCall')) { $call = $part.functionCall; $toolCalls.Add(@{ id = 'call_' + [guid]::NewGuid().ToString('N'); name = [string](Get-OmniRouteDictValue -Dictionary $call -Name 'name' -Default ''); arguments = (Get-OmniRouteDictValue -Dictionary $call -Name 'args' -Default @{}) }) }
            }
            $finishReason = [string](Get-OmniRouteDictValue -Dictionary $candidate -Name 'finishReason' -Default 'STOP')
        }
        $rawUsage = Get-OmniRouteDictValue -Dictionary $response -Name 'usageMetadata' -Default @{}
        $usage.input_tokens = [int](Get-OmniRouteDictValue -Dictionary $rawUsage -Name 'promptTokenCount' -Default 0)
        $usage.output_tokens = [int](Get-OmniRouteDictValue -Dictionary $rawUsage -Name 'candidatesTokenCount' -Default 0)
    }
    else { throw "Unsupported provider type '$($Provider.type)'." }
    return @{ id = $id; model = $Model; content = @($contentParts); toolCalls = @($toolCalls); finishReason = $finishReason; usage = $usage }
}

function ConvertFrom-OmniRouteCanonicalResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Response,
        [Parameter(Mandatory)][ValidateSet('openai-chat', 'openai-responses', 'anthropic-messages')][string]$Protocol
    )
    if ($Protocol -eq 'openai-chat') {
        $message = @{ role = 'assistant'; content = (Get-OmniRouteTextFromContent -Content $Response.content) }
        if (@($Response.toolCalls).Count -gt 0) { $message.tool_calls = @($Response.toolCalls | ForEach-Object { @{ id = $_.id; type = 'function'; function = @{ name = $_.name; arguments = ($_.arguments | ConvertTo-Json -Compress -Depth 20) } } }) }
        return @{ id = [string]$Response.id; object = 'chat.completion'; created = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); model = [string]$Response.model; choices = @(@{ index = 0; message = $message; finish_reason = [string]$Response.finishReason }); usage = @{ prompt_tokens = [int]$Response.usage.input_tokens; completion_tokens = [int]$Response.usage.output_tokens; total_tokens = ([int]$Response.usage.input_tokens + [int]$Response.usage.output_tokens) } }
    }
    if ($Protocol -eq 'openai-responses') {
        $output = [System.Collections.Generic.List[object]]::new()
        $text = Get-OmniRouteTextFromContent -Content $Response.content
        if ($text -ne '') { $output.Add(@{ id = 'msg_' + [guid]::NewGuid().ToString('N'); type = 'message'; role = 'assistant'; status = 'completed'; content = @(@{ type = 'output_text'; text = $text; annotations = @() }) }) }
        foreach ($call in @($Response.toolCalls)) { $output.Add(@{ id = 'fc_' + $call.id; type = 'function_call'; call_id = $call.id; name = $call.name; arguments = ($call.arguments | ConvertTo-Json -Compress -Depth 20); status = 'completed' }) }
        return @{ id = [string]$Response.id; object = 'response'; created_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); status = 'completed'; model = [string]$Response.model; output = @($output); output_text = $text; usage = @{ input_tokens = [int]$Response.usage.input_tokens; output_tokens = [int]$Response.usage.output_tokens; total_tokens = ([int]$Response.usage.input_tokens + [int]$Response.usage.output_tokens) } }
    }
    if ($Protocol -eq 'anthropic-messages') {
        $content = [System.Collections.Generic.List[object]]::new()
        $text = Get-OmniRouteTextFromContent -Content $Response.content
        if ($text -ne '') { $content.Add(@{ type = 'text'; text = $text }) }
        foreach ($call in @($Response.toolCalls)) { $content.Add(@{ type = 'tool_use'; id = $call.id; name = $call.name; input = $call.arguments }) }
        $stopReason = if (@($Response.toolCalls).Count -gt 0) { 'tool_use' } elseif ($Response.finishReason -in @('length', 'max_tokens')) { 'max_tokens' } else { 'end_turn' }
        return @{ id = [string]$Response.id; type = 'message'; role = 'assistant'; model = [string]$Response.model; content = @($content); stop_reason = $stopReason; usage = @{ input_tokens = [int]$Response.usage.input_tokens; output_tokens = [int]$Response.usage.output_tokens } }
    }
}

function ConvertFrom-OmniRouteProviderStreamEventToCanonical {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Data,
        [string]$EventName = '',
        [Parameter(Mandatory)][hashtable]$State
    )
    $events = [System.Collections.Generic.List[object]]::new()
    if ($Data -eq '[DONE]') { $events.Add(@{ type = 'done'; id = $State.Id; model = $State.Model }); return @($events) }

    if ($Provider.type -in @('openai', 'custom-openai', 'ollama')) {
        try { $chunk = $Data | ConvertFrom-Json -AsHashtable } catch { return @() }
        $choices = @(Get-OmniRouteDictValue -Dictionary $chunk -Name 'choices' -Default @())
        if ($choices.Count -gt 0) {
            $delta = Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'delta' -Default @{}
            $text = Get-OmniRouteDictValue -Dictionary $delta -Name 'content' -Default $null
            if ($null -ne $text -and [string]$text -ne '') { $events.Add(@{ type = 'content_delta'; id = $State.Id; model = $State.Model; text = [string]$text }) }
            foreach ($call in @(Get-OmniRouteDictValue -Dictionary $delta -Name 'tool_calls' -Default @())) {
                $function = Get-OmniRouteDictValue -Dictionary $call -Name 'function' -Default @{}
                $events.Add(@{ type = 'tool_call_delta'; id = $State.Id; model = $State.Model; toolCallId = [string](Get-OmniRouteDictValue -Dictionary $call -Name 'id' -Default $State.ToolCallId); name = [string](Get-OmniRouteDictValue -Dictionary $function -Name 'name' -Default ''); arguments = [string](Get-OmniRouteDictValue -Dictionary $function -Name 'arguments' -Default '') })
            }
            $finish = Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'finish_reason' -Default $null
            if ($null -ne $finish) { $events.Add(@{ type = 'message_end'; id = $State.Id; model = $State.Model; finishReason = [string]$finish; usage = (Get-OmniRouteDictValue -Dictionary $chunk -Name 'usage' -Default @{}) }) }
        }
        return @($events)
    }

    if ($Provider.type -eq 'anthropic') {
        try { $eventObject = $Data | ConvertFrom-Json -AsHashtable } catch { return @() }
        $eventType = [string](Get-OmniRouteDictValue -Dictionary $eventObject -Name 'type' -Default $EventName)
        switch ($eventType) {
            'message_start' { $message = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'message' -Default @{}; $State.Id = [string](Get-OmniRouteDictValue -Dictionary $message -Name 'id' -Default $State.Id); $State.Model = [string](Get-OmniRouteDictValue -Dictionary $message -Name 'model' -Default $State.Model); $events.Add(@{ type = 'message_start'; id = $State.Id; model = $State.Model; usage = (Get-OmniRouteDictValue -Dictionary $message -Name 'usage' -Default @{}) }) }
            'content_block_delta' { $delta = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'delta' -Default @{}; if ([string](Get-OmniRouteDictValue -Dictionary $delta -Name 'type' -Default '') -eq 'text_delta') { $events.Add(@{ type = 'content_delta'; id = $State.Id; model = $State.Model; text = [string](Get-OmniRouteDictValue -Dictionary $delta -Name 'text' -Default '') }) } elseif ([string](Get-OmniRouteDictValue -Dictionary $delta -Name 'type' -Default '') -eq 'input_json_delta') { $events.Add(@{ type = 'tool_call_delta'; id = $State.Id; model = $State.Model; toolCallId = $State.ToolCallId; arguments = [string](Get-OmniRouteDictValue -Dictionary $delta -Name 'partial_json' -Default '') }) } }
            'content_block_start' { $block = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'content_block' -Default @{}; if ([string](Get-OmniRouteDictValue -Dictionary $block -Name 'type' -Default '') -eq 'tool_use') { $State.ToolCallId = [string](Get-OmniRouteDictValue -Dictionary $block -Name 'id' -Default ('tool_' + [guid]::NewGuid().ToString('N'))); $events.Add(@{ type = 'tool_call_start'; id = $State.Id; model = $State.Model; toolCallId = $State.ToolCallId; name = [string](Get-OmniRouteDictValue -Dictionary $block -Name 'name' -Default ''); arguments = '' }) } }
            'message_delta' { $delta = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'delta' -Default @{}; $usage = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'usage' -Default @{}; $events.Add(@{ type = 'message_end'; id = $State.Id; model = $State.Model; finishReason = [string](Get-OmniRouteDictValue -Dictionary $delta -Name 'stop_reason' -Default 'end_turn'); usage = $usage }) }
            'message_stop' { $events.Add(@{ type = 'done'; id = $State.Id; model = $State.Model }) }
            'error' { $events.Add(@{ type = 'error'; id = $State.Id; model = $State.Model; error = (Get-OmniRouteDictValue -Dictionary $eventObject -Name 'error' -Default @{ message = 'Anthropic stream error' }) }) }
        }
        return @($events)
    }

    if ($Provider.type -eq 'gemini') {
        try { $eventObject = $Data | ConvertFrom-Json -AsHashtable } catch { return @() }
        foreach ($candidate in @(Get-OmniRouteDictValue -Dictionary $eventObject -Name 'candidates' -Default @())) {
            $content = Get-OmniRouteDictValue -Dictionary $candidate -Name 'content' -Default @{}
            foreach ($part in @(Get-OmniRouteDictValue -Dictionary $content -Name 'parts' -Default @())) {
                if ($part.Contains('text')) { $events.Add(@{ type = 'content_delta'; id = $State.Id; model = $State.Model; text = [string]$part.text }) }
                if ($part.Contains('functionCall')) { $call = $part.functionCall; $events.Add(@{ type = 'tool_call_start'; id = $State.Id; model = $State.Model; toolCallId = ('call_' + [guid]::NewGuid().ToString('N')); name = [string](Get-OmniRouteDictValue -Dictionary $call -Name 'name' -Default ''); arguments = (Get-OmniRouteDictValue -Dictionary $call -Name 'args' -Default @{}) }) }
            }
            $finish = Get-OmniRouteDictValue -Dictionary $candidate -Name 'finishReason' -Default $null
            if ($null -ne $finish) { $events.Add(@{ type = 'message_end'; id = $State.Id; model = $State.Model; finishReason = [string]$finish; usage = @{} }) }
        }
        return @($events)
    }
    return @($events)
}

function ConvertFrom-OmniRouteCanonicalStreamEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$StreamEvent,
        [Parameter(Mandatory)][ValidateSet('openai-chat', 'openai-responses', 'anthropic-messages')][string]$Protocol,
        [Parameter(Mandatory)][hashtable]$State
    )
    $null = $State
    $type = [string]$StreamEvent.type
    if ($Protocol -eq 'openai-chat') {
        if ($type -eq 'done') { return @('data: [DONE]') }
        if ($type -eq 'message_start') { return @() }
        if ($type -eq 'content_delta') { return @('data: ' + (@{ id = $StreamEvent.id; object = 'chat.completion.chunk'; model = $StreamEvent.model; choices = @(@{ index = 0; delta = @{ content = $StreamEvent.text }; finish_reason = $null }) } | ConvertTo-Json -Compress -Depth 20)) }
        if ($type -in @('tool_call_start', 'tool_call_delta')) {
            $function = [ordered]@{}
            if ($type -eq 'tool_call_start') { $function.name = $StreamEvent.name }
            if ($null -ne $StreamEvent.arguments) { $function.arguments = if ($StreamEvent.arguments -is [string]) { $StreamEvent.arguments } else { $StreamEvent.arguments | ConvertTo-Json -Compress -Depth 20 } }
            return @('data: ' + (@{ id = $StreamEvent.id; object = 'chat.completion.chunk'; model = $StreamEvent.model; choices = @(@{ index = 0; delta = @{ tool_calls = @(@{ index = 0; id = $StreamEvent.toolCallId; type = 'function'; function = $function }) }; finish_reason = $null }) } | ConvertTo-Json -Compress -Depth 20))
        }
        if ($type -eq 'message_end') { return @('data: ' + (@{ id = $StreamEvent.id; object = 'chat.completion.chunk'; model = $StreamEvent.model; choices = @(@{ index = 0; delta = @{}; finish_reason = $StreamEvent.finishReason }); usage = $StreamEvent.usage } | ConvertTo-Json -Compress -Depth 20)) }
        if ($type -eq 'error') { return @('data: ' + (@{ error = $StreamEvent.error } | ConvertTo-Json -Compress -Depth 20)) }
        return @()
    }
    if ($Protocol -eq 'openai-responses') {
        if ($type -eq 'content_delta') { return @('event: response.output_text.delta', ('data: ' + (@{ type = 'response.output_text.delta'; delta = $StreamEvent.text } | ConvertTo-Json -Compress -Depth 20))) }
        if ($type -eq 'message_end') { return @('event: response.completed', ('data: ' + (@{ type = 'response.completed'; response = @{ id = $StreamEvent.id; status = 'completed'; model = $StreamEvent.model } } | ConvertTo-Json -Compress -Depth 20))) }
        if ($type -eq 'done') { return @() }
        if ($type -eq 'error') { return @('event: response.failed', ('data: ' + (@{ type = 'response.failed'; error = $StreamEvent.error } | ConvertTo-Json -Compress -Depth 20))) }
        return @()
    }
    if ($Protocol -eq 'anthropic-messages') {
        switch ($type) {
            'message_start' { return @('event: message_start', 'data: ' + (@{ type = 'message_start'; message = @{ id = $StreamEvent.id; type = 'message'; role = 'assistant'; model = $StreamEvent.model; content = @(); usage = @{ input_tokens = [int](Get-OmniRouteDictValue -Dictionary $StreamEvent.usage -Name 'input_tokens' -Default 0); output_tokens = 0 } } } | ConvertTo-Json -Compress -Depth 20)) }
            'content_delta' { return @('event: content_block_delta', 'data: ' + (@{ type = 'content_block_delta'; index = 0; delta = @{ type = 'text_delta'; text = $StreamEvent.text } } | ConvertTo-Json -Compress -Depth 20)) }
            'tool_call_start' { return @('event: content_block_start', 'data: ' + (@{ type = 'content_block_start'; index = 1; content_block = @{ type = 'tool_use'; id = $StreamEvent.toolCallId; name = $StreamEvent.name } } | ConvertTo-Json -Compress -Depth 20)) }
            'tool_call_delta' { return @('event: content_block_delta', 'data: ' + (@{ type = 'content_block_delta'; index = 1; delta = @{ type = 'input_json_delta'; partial_json = [string]$StreamEvent.arguments } } | ConvertTo-Json -Compress -Depth 20)) }
            'message_end' { return @('event: message_delta', 'data: ' + (@{ type = 'message_delta'; delta = @{ stop_reason = $StreamEvent.finishReason }; usage = @{ input_tokens = [int](Get-OmniRouteDictValue -Dictionary $StreamEvent.usage -Name 'input_tokens' -Default 0); output_tokens = [int](Get-OmniRouteDictValue -Dictionary $StreamEvent.usage -Name 'output_tokens' -Default 0) } } | ConvertTo-Json -Compress -Depth 20)) }
            'done' { return @('event: message_stop', 'data: {"type":"message_stop"}') }
            'error' { return @('event: error', 'data: ' + (@{ type = 'error'; error = $StreamEvent.error } | ConvertTo-Json -Compress -Depth 20)) }
        }
        return @()
    }
    return @()
}
