defmodule PCIStatus.Build do
  @moduledoc """
  What's actually running: version, commit, build and deploy times.

  Inside a release there's no `.git` directory and no Mix, so this reads from
  environment variables that the build injects. The Docker pattern is:

      ARG GIT_SHA
      ENV GIT_SHA=${GIT_SHA}

  built with `docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD)`.
  Without them you still get the OTP application version, which is enough for
  the portal to detect a deploy.
  """

  alias PCIStatus.Config

  @doc """
  Version string for the payload's top-level `version` field, e.g.
  `"0.1.0+9f3ac21"`. This is what the portal badges and diffs to announce a
  deploy, so it must change when the code changes — hence the commit suffix.
  """
  def version do
    base = app_version()
    sha = git_sha()

    case {base, sha} do
      {nil, nil} -> "unknown"
      {base, nil} -> base
      {nil, sha} -> sha
      {base, sha} -> "#{base}+#{sha}"
    end
  end

  @doc "Flat map of build provenance for the payload's `application` section."
  def info do
    %{
      app_version: app_version(),
      git_sha: git_sha(),
      git_branch: env(["GIT_BRANCH", "SOURCE_BRANCH"]),
      built_at: env(["BUILT_AT", "BUILD_TIMESTAMP"]),
      deployed_at: deployed_at(),
      environment: Config.environment(),
      release_name: env(["RELEASE_NAME"]),
      release_vsn: env(["RELEASE_VSN"])
    }
  end

  defp app_version do
    case Config.otp_app() do
      nil ->
        nil

      app ->
        case Application.spec(app, :vsn) do
          nil -> nil
          vsn -> List.to_string(vsn)
        end
    end
  end

  defp git_sha do
    case env(["GIT_SHA", "GIT_COMMIT", "SOURCE_COMMIT", "RELEASE_COMMIT"]) do
      nil -> nil
      sha -> String.slice(sha, 0, 12)
    end
  end

  # Falls back to the boot time of this node, which for a container is the
  # deploy time in every case that matters.
  defp deployed_at do
    case env(["DEPLOYED_AT"]) do
      nil -> boot_time()
      value -> value
    end
  end

  defp boot_time do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    DateTime.utc_now()
    |> DateTime.add(-div(uptime_ms, 1000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  rescue
    _ -> nil
  end

  defp env(vars) do
    Enum.find_value(vars, fn var ->
      case System.get_env(var) do
        nil -> nil
        "" -> nil
        value -> String.trim(value)
      end
    end)
  end
end
