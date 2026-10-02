Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OmniRouteProviderHeaders {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Provider)

    $headers = @{
        'Accept' = 'application/json'
    }
    foreach ($name in $Provider.headers.Keys) {
        $headers[$name] = [string]$Provider.headers[$name]
    }
    if ($Provider.type -eq 'anthropic' -and -not $headers.ContainsKey('anthropic-version')) {
        $headers['anthropic-version'] = '2023-06-01'
    }

    $apiKey = Get-OmniRouteApiKey -Provider $Provider
    if (-not [string]::IsNullOrEmpty($apiKey)) {
        $headers[[string]$Provider.apiKeyHeader] = [string]$Provider.apiKeyPrefix + $apiKey
    }
    return $headers
}

function Get-OmniRouteProviderEndpoint {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][bool]$Stream
    )

    switch ($Provider.type) {
        'openai' { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'chat/completions' }
        'custom-openai' { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'chat/completions' }
        'ollama' { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'chat/completions' }
        'anthropic' { return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'messages' }
        'gemini' {
            $encodedModel = [Uri]::EscapeDataString($Model)
            if ($Stream) {
                return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path "models/$encodedModel`:streamGenerateContent?alt=sse"
            }
            return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path "models/$encodedModel`:generateContent"
        }
        default { throw "Unsupported provider type '$($Provider.type)'." }
    }
}

function Get-OmniRouteProviderProbeUri {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Provider)

    if (-not [string]::IsNullOrWhiteSpace([string]$Provider.healthPath)) {
        return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path ([string]$Provider.healthPath)
    }
    return Resolve-OmniRouteUri -BaseUrl $Provider.baseUrl -Path 'models'
}

function Copy-OmniRouteDictionary {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$InputObject)

    $copy = [ordered]@{}
    foreach ($key in $InputObject.Keys) { $copy[$key] = $InputObject[$key] }
    return $copy
}

function ConvertTo-OmniRouteProviderRequest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][hashtable]$RequestBody,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][bool]$Stream
    )

    switch ($Provider.type) {
        { $_ -in @('openai', 'custom-openai', 'ollama') } {
            $body = Copy-OmniRouteDictionary -InputObject $RequestBody
            $body.model = $Model
            $body.stream = $Stream
            return $body
        }
        'anthropic' {
            $systemParts = [System.Collections.Generic.List[string]]::new()
            $messages = [System.Collections.Generic.List[object]]::new()
            foreach ($message in @($RequestBody.messages)) {
                $role = [string](Get-OmniRouteDictValue -Dictionary $message -Name 'role' -Default 'user')
                $content = Get-OmniRouteDictValue -Dictionary $message -Name 'content' -Default ''
                $text = if ($content -is [string]) { $content } else { ($content | ForEach-Object { [string](Get-OmniRouteDictValue -Dictionary $_ -Name 'text' -Default '') }) -join "`n" }
                if ($role -eq 'system') { $systemParts.Add($text); continue }
                if ($role -eq 'tool') { throw 'Unsupported parameter: Anthropic adapter does not implement tool-role messages in v0.1.' }
                $messages.Add(@{ role = $role; content = $text })
            }
            $maxTokens = Get-OmniRouteDictValue -Dictionary $RequestBody -Name 'max_tokens' -Default $null
            if ($null -eq $maxTokens) { $maxTokens = Get-OmniRouteDictValue -Dictionary $RequestBody -Name 'max_completion_tokens' -Default 4096 }
            $body = [ordered]@{
                model      = $Model
                messages   = @($messages)
                max_tokens = [int]$maxTokens
                stream     = $Stream
            }
            if ($systemParts.Count -gt 0) { $body.system = ($systemParts -join "`n") }
            foreach ($name in @('temperature', 'top_p', 'stop', 'metadata')) {
                if ($RequestBody.Contains($name)) { $body[$name] = $RequestBody[$name] }
            }
            return $body
        }
        'gemini' {
            $systemParts = [System.Collections.Generic.List[string]]::new()
            $contents = [System.Collections.Generic.List[object]]::new()
            foreach ($message in @($RequestBody.messages)) {
                $role = [string](Get-OmniRouteDictValue -Dictionary $message -Name 'role' -Default 'user')
                $content = Get-OmniRouteDictValue -Dictionary $message -Name 'content' -Default ''
                $text = if ($content -is [string]) { $content } else { ($content | ForEach-Object { [string](Get-OmniRouteDictValue -Dictionary $_ -Name 'text' -Default '') }) -join "`n" }
                if ($role -eq 'system') { $systemParts.Add($text); continue }
                $geminiRole = if ($role -eq 'assistant') { 'model' } elseif ($role -eq 'user') { 'user' } else { throw "Unsupported parameter: Gemini adapter does not support role '$role'." }
                $contents.Add(@{ role = $geminiRole; parts = @(@{ text = $text }) })
            }
            $body = [ordered]@{
                contents = @($contents)
            }
            if ($systemParts.Count -gt 0) {
                $body.systemInstruction = @{ parts = @(@{ text = ($systemParts -join "`n") }) }
            }
            $generationConfig = [ordered]@{}
            if ($RequestBody.Contains('temperature')) { $generationConfig.temperature = $RequestBody.temperature }
            if ($RequestBody.Contains('top_p')) { $generationConfig.topP = $RequestBody.top_p }
            if ($RequestBody.Contains('max_tokens')) { $generationConfig.maxOutputTokens = $RequestBody.max_tokens }
            elseif ($RequestBody.Contains('max_completion_tokens')) { $generationConfig.maxOutputTokens = $RequestBody.max_completion_tokens }
            if ($RequestBody.Contains('stop')) { $generationConfig.stopSequences = @($RequestBody.stop) }
            if ($generationConfig.Count -gt 0) { $body.generationConfig = $generationConfig }
            return $body
        }
        default { throw "Unsupported provider type '$($Provider.type)'." }
    }
}

function ConvertTo-OmniRouteResponsesChatRequest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$RequestBody)

    $supported = @('model', 'input', 'instructions', 'stream', 'temperature', 'top_p', 'max_output_tokens', 'stop', 'user', 'seed')
    foreach ($key in $RequestBody.Keys) {
        if ($key -notin $supported) {
            throw "Unsupported parameter: '$key' is not supported by the limited /v1/responses compatibility layer."
        }
    }
    if (-not $RequestBody.Contains('input')) { throw "Invalid request: 'input' is required." }

    $messages = [System.Collections.Generic.List[object]]::new()
    if ($RequestBody.Contains('instructions') -and -not [string]::IsNullOrWhiteSpace([string]$RequestBody.instructions)) {
        $messages.Add(@{ role = 'system'; content = [string]$RequestBody.instructions })
    }

    $inputValue = $RequestBody.input
    if ($inputValue -is [string]) {
        $messages.Add(@{ role = 'user'; content = $inputValue })
    }
    elseif ($inputValue -is [System.Collections.IEnumerable] -and $inputValue -isnot [System.Collections.IDictionary]) {
        foreach ($item in @($inputValue)) {
            if ($item -is [string]) {
                $messages.Add(@{ role = 'user'; content = [string]$item })
                continue
            }
            if ($item -isnot [System.Collections.IDictionary]) { throw 'Invalid request: input items must be strings or objects.' }
            $role = [string](Get-OmniRouteDictValue -Dictionary $item -Name 'role' -Default 'user')
            $contentValue = Get-OmniRouteDictValue -Dictionary $item -Name 'content' -Default ''
            if ($contentValue -is [string]) {
                $messages.Add(@{ role = $role; content = $contentValue })
                continue
            }
            $textParts = [System.Collections.Generic.List[string]]::new()
            foreach ($part in @($contentValue)) {
                $partType = [string](Get-OmniRouteDictValue -Dictionary $part -Name 'type' -Default '')
                if ($partType -notin @('input_text', 'output_text', 'text')) {
                    throw "Unsupported parameter: responses input part '$partType' is not supported."
                }
                $textParts.Add([string](Get-OmniRouteDictValue -Dictionary $part -Name 'text' -Default ''))
            }
            $messages.Add(@{ role = $role; content = ($textParts -join "`n") })
        }
    }
    else {
        throw "Invalid request: 'input' must be a string or an array."
    }

    $chat = [ordered]@{
        model    = [string]$RequestBody.model
        messages = @($messages)
        stream   = [bool](Get-OmniRouteDictValue -Dictionary $RequestBody -Name 'stream' -Default $false)
    }
    $mapping = @{
        temperature       = 'temperature'
        top_p             = 'top_p'
        max_output_tokens = 'max_tokens'
        stop              = 'stop'
        user              = 'user'
        seed              = 'seed'
    }
    foreach ($source in $mapping.Keys) {
        if ($RequestBody.Contains($source)) { $chat[$mapping[$source]] = $RequestBody[$source] }
    }
    return $chat
}

function Get-OmniRouteResponseText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Response)

    $choices = @(Get-OmniRouteDictValue -Dictionary $Response -Name 'choices' -Default @())
    if (@($choices).Count -eq 0) { return '' }
    $message = Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'message' -Default $null
    if ($null -ne $message) {
        $content = Get-OmniRouteDictValue -Dictionary $message -Name 'content' -Default ''
        if ($content -is [string]) { return $content }
    }
    $delta = Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'delta' -Default $null
    if ($null -ne $delta) {
        $content = Get-OmniRouteDictValue -Dictionary $delta -Name 'content' -Default ''
        if ($content -is [string]) { return $content }
    }
    return ''
}

function ConvertFrom-OmniRouteProviderResponse {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Model
    )

    try { $response = $Content | ConvertFrom-Json -AsHashtable }
    catch { throw "Malformed upstream JSON: $($_.Exception.Message)" }
    if ($response -isnot [System.Collections.IDictionary]) { throw 'Malformed upstream JSON: expected an object.' }

    switch ($Provider.type) {
        { $_ -in @('openai', 'custom-openai', 'ollama') } {
            return $response
        }
        'anthropic' {
            $textParts = [System.Collections.Generic.List[string]]::new()
            foreach ($part in @(Get-OmniRouteDictValue -Dictionary $response -Name 'content' -Default @())) {
                if ([string](Get-OmniRouteDictValue -Dictionary $part -Name 'type' -Default '') -eq 'text') {
                    $textParts.Add([string](Get-OmniRouteDictValue -Dictionary $part -Name 'text' -Default ''))
                }
            }
            $usage = Get-OmniRouteDictValue -Dictionary $response -Name 'usage' -Default @{}
            $inputTokens = [int](Get-OmniRouteDictValue -Dictionary $usage -Name 'input_tokens' -Default 0)
            $outputTokens = [int](Get-OmniRouteDictValue -Dictionary $usage -Name 'output_tokens' -Default 0)
            return [ordered]@{
                id      = [string](Get-OmniRouteDictValue -Dictionary $response -Name 'id' -Default ('chatcmpl-' + [guid]::NewGuid().ToString('N')))
                object  = 'chat.completion'
                created = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                model   = $Model
                choices = @([ordered]@{
                    index         = 0
                    message       = @{ role = 'assistant'; content = ($textParts -join '') }
                    finish_reason = [string](Get-OmniRouteDictValue -Dictionary $response -Name 'stop_reason' -Default 'stop')
                })
                usage   = @{ prompt_tokens = $inputTokens; completion_tokens = $outputTokens; total_tokens = ($inputTokens + $outputTokens) }
            }
        }
        'gemini' {
            $textParts = [System.Collections.Generic.List[string]]::new()
            foreach ($candidate in @(Get-OmniRouteDictValue -Dictionary $response -Name 'candidates' -Default @())) {
                $content = Get-OmniRouteDictValue -Dictionary $candidate -Name 'content' -Default @{}
                foreach ($part in @(Get-OmniRouteDictValue -Dictionary $content -Name 'parts' -Default @())) {
                    $text = Get-OmniRouteDictValue -Dictionary $part -Name 'text' -Default $null
                    if ($null -ne $text) { $textParts.Add([string]$text) }
                }
            }
            $usage = Get-OmniRouteDictValue -Dictionary $response -Name 'usageMetadata' -Default @{}
            $inputTokens = [int](Get-OmniRouteDictValue -Dictionary $usage -Name 'promptTokenCount' -Default 0)
            $outputTokens = [int](Get-OmniRouteDictValue -Dictionary $usage -Name 'candidatesTokenCount' -Default 0)
            return [ordered]@{
                id      = 'chatcmpl-' + [guid]::NewGuid().ToString('N')
                object  = 'chat.completion'
                created = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                model   = $Model
                choices = @([ordered]@{
                    index         = 0
                    message       = @{ role = 'assistant'; content = ($textParts -join '') }
                    finish_reason = 'stop'
                })
                usage   = @{ prompt_tokens = $inputTokens; completion_tokens = $outputTokens; total_tokens = ($inputTokens + $outputTokens) }
            }
        }
        default { throw "Unsupported provider type '$($Provider.type)'." }
    }
}

function ConvertFrom-OmniRouteChatToResponses {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ChatResponse,
        [Parameter(Mandatory)][string]$Model
    )
    $text = Get-OmniRouteResponseText -Response $ChatResponse
    $id = [string](Get-OmniRouteDictValue -Dictionary $ChatResponse -Name 'id' -Default ('resp_' + [guid]::NewGuid().ToString('N')))
    if ($id.StartsWith('chatcmpl-')) { $id = 'resp_' + $id.Substring(9) }
    $usage = Get-OmniRouteDictValue -Dictionary $ChatResponse -Name 'usage' -Default @{}
    $prompt = [int](Get-OmniRouteDictValue -Dictionary $usage -Name 'prompt_tokens' -Default 0)
    $completion = [int](Get-OmniRouteDictValue -Dictionary $usage -Name 'completion_tokens' -Default 0)
    return [ordered]@{
        id          = $id
        object      = 'response'
        created_at  = [int](Get-OmniRouteDictValue -Dictionary $ChatResponse -Name 'created' -Default ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
        status      = 'completed'
        model       = $Model
        output      = @([ordered]@{
            id      = 'msg_' + [guid]::NewGuid().ToString('N')
            type    = 'message'
            role    = 'assistant'
            status  = 'completed'
            content = @([ordered]@{ type = 'output_text'; text = $text; annotations = @() })
        })
        output_text = $text
        usage       = @{
            input_tokens  = $prompt
            output_tokens = $completion
            total_tokens  = $prompt + $completion
        }
    }
}

function Get-OmniRouteOpenAiChunkText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Data)
    if ($Data -eq '[DONE]') { return '' }
    try { $chunk = $Data | ConvertFrom-Json -AsHashtable }
    catch { return '' }
    $choices = @(Get-OmniRouteDictValue -Dictionary $chunk -Name 'choices' -Default @())
    if (@($choices).Count -eq 0) { return '' }
    $delta = Get-OmniRouteDictValue -Dictionary $choices[0] -Name 'delta' -Default @{}
    $content = Get-OmniRouteDictValue -Dictionary $delta -Name 'content' -Default ''
    if ($content -is [string]) { return $content }
    return ''
}

function New-OmniRouteChatChunk {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Model,
        [string]$Id = ('chatcmpl-' + [guid]::NewGuid().ToString('N')),
        [bool]$Done = $false
    )
    $chunk = [ordered]@{
        id      = $Id
        object  = 'chat.completion.chunk'
        created = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        model   = $Model
        choices = @()
    }
    if ($Done) {
        $chunk.choices = @([ordered]@{ index = 0; delta = @{}; finish_reason = 'stop' })
    }
    else {
        $chunk.choices = @([ordered]@{ index = 0; delta = @{ content = $Text }; finish_reason = $null })
    }
    return ($chunk | ConvertTo-Json -Depth 20 -Compress)
}

function ConvertFrom-OmniRouteProviderStreamEvent {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Data,
        [string]$EventName = '',
        [ValidateSet('chat', 'responses')][string]$Endpoint = 'chat',
        [Parameter(Mandatory)][hashtable]$State
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $openAiData = $null

    switch ($Provider.type) {
        { $_ -in @('openai', 'custom-openai', 'ollama') } { $openAiData = $Data }
        'anthropic' {
            if ([string]::IsNullOrWhiteSpace($Data)) { return @() }
            $eventObject = $Data | ConvertFrom-Json -AsHashtable
            $eventType = [string](Get-OmniRouteDictValue -Dictionary $eventObject -Name 'type' -Default $EventName)
            if ($eventType -eq 'message_start') {
                $message = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'message' -Default @{}
                $State.Id = [string](Get-OmniRouteDictValue -Dictionary $message -Name 'id' -Default $State.Id)
                return @()
            }
            if ($eventType -eq 'content_block_delta') {
                $delta = Get-OmniRouteDictValue -Dictionary $eventObject -Name 'delta' -Default @{}
                $text = [string](Get-OmniRouteDictValue -Dictionary $delta -Name 'text' -Default '')
                if ($text.Length -gt 0) { $openAiData = 'data: ' + (New-OmniRouteChatChunk -Text $text -Model $State.Model -Id $State.Id) }
            }
            elseif ($eventType -eq 'message_stop') { $openAiData = 'data: [DONE]' }
            if ($null -eq $openAiData) { return @() }
        }
        'gemini' {
            if ([string]::IsNullOrWhiteSpace($Data)) { return @() }
            $eventObject = $Data | ConvertFrom-Json -AsHashtable
            $text = [System.Text.StringBuilder]::new()
            foreach ($candidate in @(Get-OmniRouteDictValue -Dictionary $eventObject -Name 'candidates' -Default @())) {
                $content = Get-OmniRouteDictValue -Dictionary $candidate -Name 'content' -Default @{}
                foreach ($part in @(Get-OmniRouteDictValue -Dictionary $content -Name 'parts' -Default @())) {
                    $partText = Get-OmniRouteDictValue -Dictionary $part -Name 'text' -Default ''
                    if ($null -ne $partText) { [void]$text.Append([string]$partText) }
                }
            }
            if ($text.Length -gt 0) { $openAiData = 'data: ' + (New-OmniRouteChatChunk -Text $text.ToString() -Model $State.Model -Id $State.Id) }
            else { return @() }
        }
        default { throw "Unsupported provider type '$($Provider.type)'." }
    }

    if ([string]::IsNullOrWhiteSpace($openAiData)) { return @() }
    if ($Endpoint -eq 'chat') {
        $lines.Add($openAiData)
        return @($lines)
    }

    if ($openAiData -eq 'data: [DONE]') {
        $lines.Add('event: response.completed')
        $lines.Add('data: ' + (@{ type = 'response.completed'; response = (@{ id = $State.Id; object = 'response'; status = 'completed'; model = $State.Model; output_text = $State.Text.ToString() }) } | ConvertTo-Json -Depth 20 -Compress))
        $State.SawDone = $true
        return @($lines)
    }
    $jsonText = $openAiData.Substring(6)
    $chunkText = Get-OmniRouteOpenAiChunkText -Data $jsonText
    if ($chunkText.Length -eq 0) { return @() }
    [void]$State.Text.Append($chunkText)
    $lines.Add('event: response.output_text.delta')
    $lines.Add('data: ' + (@{ type = 'response.output_text.delta'; delta = $chunkText } | ConvertTo-Json -Depth 20 -Compress))
    return @($lines)
}
