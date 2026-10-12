defmodule Dokkit.Ipv6ListenerTest do
  use ExUnit.Case, async: true

  @all_v6 {0, 0, 0, 0, 0, 0, 0, 0}

  test "an IPv4 wildcard address gets a second listener on the IPv6 wildcard, with the same scheme and options" do
    [spec] = Dokkit.Application.ipv6_listener(http: [ip: {0, 0, 0, 0}, port: 8080])
    assert spec.id == :ipv6_listener
    opts = spec.start |> elem(2) |> hd()
    assert opts[:ip] == @all_v6 and opts[:port] == 8080 and opts[:scheme] == :http

    [spec] =
      Dokkit.Application.ipv6_listener(
        https: [ip: {0, 0, 0, 0}, port: 443],
        http: [ip: {127, 0, 0, 1}]
      )

    assert spec.start |> elem(2) |> hd() |> Keyword.fetch!(:scheme) == :https
  end

  test "any other address gets none" do
    assert Dokkit.Application.ipv6_listener(http: [ip: {127, 0, 0, 1}, port: 4000]) == []
    assert Dokkit.Application.ipv6_listener(http: [ip: @all_v6, port: 4000]) == []
    assert Dokkit.Application.ipv6_listener([]) == []
  end
end
