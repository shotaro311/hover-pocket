using System.Text.Json;

namespace HoverPocket.Shell.Bridge;

internal sealed class BridgeDispatcher
{
    private readonly Dictionary<string, Func<JsonElement?, CancellationToken, Task<object?>>> _handlers =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Func<string, Task>? _postJsonAsync;

    public BridgeDispatcher(Func<string, Task>? postJsonAsync = null)
    {
        _postJsonAsync = postJsonAsync;
    }

    public void Register(string method, Func<JsonElement?, CancellationToken, Task<object?>> handler)
    {
        _handlers[method] = handler;
    }

    public async Task<string?> ProcessRawMessageAsync(string rawMessage, CancellationToken cancellationToken = default)
    {
        BridgeRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<BridgeRequest>(rawMessage, BridgeJson.Options);
        }
        catch (JsonException ex)
        {
            return SerializeResponse(null, null, new BridgeError("invalid_json", ex.Message));
        }

        if (request is null)
        {
            return SerializeResponse(null, null, new BridgeError("empty_request", "Bridge request was empty."));
        }

        if (string.IsNullOrWhiteSpace(request.Id) || string.IsNullOrWhiteSpace(request.Method))
        {
            return SerializeResponse(request.Id, null, new BridgeError("invalid_request", "Bridge request requires id and method."));
        }

        if (!_handlers.TryGetValue(request.Method, out var handler))
        {
            return SerializeResponse(request.Id, null, new BridgeError("unknown_method", $"Unknown bridge method: {request.Method}"));
        }

        try
        {
            var result = await handler(request.Params, cancellationToken);
            return SerializeResponse(request.Id, result, null);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            return SerializeResponse(request.Id, null, new BridgeError("handler_error", ex.Message));
        }
    }

    public async Task HandleRawMessageAsync(string rawMessage, CancellationToken cancellationToken = default)
    {
        var response = await ProcessRawMessageAsync(rawMessage, cancellationToken);
        if (response is not null && _postJsonAsync is not null)
        {
            await _postJsonAsync(response);
        }
    }

    public Task PostEventAsync(string eventName, object? payload)
    {
        if (_postJsonAsync is null)
        {
            return Task.CompletedTask;
        }

        var json = JsonSerializer.Serialize(new BridgeEvent(eventName, payload), BridgeJson.Options);
        return _postJsonAsync(json);
    }

    private static string SerializeResponse(string? id, object? result, BridgeError? error)
    {
        return JsonSerializer.Serialize(new BridgeResponse(id, result, error), BridgeJson.Options);
    }
}

internal sealed record BridgeRequest(string? Id, string? Method, JsonElement? Params);

internal sealed record BridgeResponse(string? Id, object? Result, BridgeError? Error);

internal sealed record BridgeError(string Code, string Message);

internal sealed record BridgeEvent(string Event, object? Payload);
