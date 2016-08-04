defmodule Swarm.Cluster.Kubernetes do
  @moduledoc """
  This clustering strategy works by loading all pods in the current Kubernetes
  namespace with the configured tag. It will fetch the addresses of all pods with
  that tag and attempt to connect. It will continually monitor and update it's
  connections every 1s.

  It assumes that all nodes share a base name, are using longnames, and are unique
  based on their FQDN, rather than the base hostname.
  """
  use GenServer
  import Swarm.Logger

  @service_account_path "/var/run/secrets/kubernetes.io/serviceaccount"

  def start_link(), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(_) do
    {:ok, MapSet.new([]), 0}
  end

  def handle_info(:timeout, nodelist) do
    handle_info(:load, nodelist)
  end
  def handle_info(:load, nodelist) do
    new_nodelist = MapSet.new(get_nodes())
    added        = MapSet.difference(new_nodelist, nodelist)
    removed      = MapSet.difference(nodelist, new_nodelist)
    for n <- removed do
      debug "disconnected from #{inspect n}"
    end
    connect_nodes(added)
    Process.send_after(self(), :load, 5_000)
    {:noreply, new_nodelist}
  end
  def handle_info(_, nodelist) do
    {:noreply, nodelist}
  end

  defp get_token() do
    path = Path.join(@service_account_path, "token")
    case File.exists?(path) do
      true  -> path |> File.read! |> String.trim()
      false -> ""
    end
  end

  defp get_namespace() do
    path = Path.join(@service_account_path, "namespace")
    case File.exists?(path) do
      true  -> path |> File.read! |> String.trim()
      false -> ""
    end
  end

  @kubernetes_master "kubernetes.default.svc.cluster.local"
  defp get_nodes() do
    token     = get_token()
    namespace = get_namespace()
    app_name = Application.get_env(:swarm, :kubernetes_node_basename)
    selector = Application.get_env(:swarm, :kubernetes_selector, "")
    selector = URI.encode(selector)
    endpoints_path = "api/v1/namespaces/#{namespace}/pods?labelSelector=#{selector}"
    headers        = [{'authorization', 'Bearer #{token}'}]
    http_options   = [ssl: [verify: :verify_none]]
    case :httpc.request(:get, {"https://#{@kubernetes_master}/#{endpoints_path}", headers}, http_options, []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        case Poison.decode!(body) do
          %{"items" => []} ->
            []
          %{"items" => items} ->
            Enum.reduce(items, [], fn
              %{"status" => %{"phase" => "Running", "podIP" => pod_addr}}, acc ->
                [:"#{app_name}@#{pod_addr}"|acc]
              _, acc ->
                acc
            end)
          _ ->
            []
        end
      {:ok, {{_version, 403, _status}, _headers, body}} ->
        resp = Poison.decode!(body)
        warn "cannot query kubernetes (unauthorized): #{resp.message}"
        []
      {:ok, {{_version, code, status}, _headers, body}} ->
        warn "cannot query kubernetes (#{code} #{status}): #{inspect body}"
        []
      {:error, reason} ->
        error "request to kubernetes failed!: #{inspect reason}"
        []
    end
  end

  defp connect_nodes(nodes) do
    for n <- nodes do
      case :net_kernel.connect_node(n) do
        true ->
          debug "connected to #{inspect n}"
          :ok
        reason ->
          debug "attempted to connect to node (#{inspect n}), but failed with #{reason}."
          :ok
      end
    end
    :ok
  end
end