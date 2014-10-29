defmodule Radius do
  alias RadiusDict.Attribute
  alias RadiusDict.Vendor
  alias RadiusDict.Value
  alias RadiusDict.EntryNotFoundError
  require Logger
  defmodule Packet do
    defstruct code: nil, id: nil, length: nil, auth: nil, attrs: [], raw: nil, secret: nil
    def decode(data,secret) do
      pkt = %{raw: data, secret: secret, attrs: nil} 
        |> decode_header
        |> decode_payload
      struct Packet,pkt

    end #def decode/2

    defp decode_header(%{raw: <<code, id, length :: size(16), auth ::binary-size(16), rest :: binary>>}=ctx) do
      if byte_size(rest) < length-20 do
        {:error,:packet_too_short}
      else
        if byte_size(ctx.raw) != length do
          raise "Packet length not match."
        end
        Map.merge ctx,%{code: decode_code(code), id: id, length: length, auth: auth, rest: rest}
      end
    end

    defp decode_code(1),  do: "Access-Request"
    defp decode_code(2),  do: "Access-Accept"
    defp decode_code(3),  do: "Access-Reject"
    defp decode_code(11), do: "Access-Challenge"
    defp decode_code(4),  do: "Accounting-Request"
    defp decode_code(5),  do: "Accounting-Response"
    defp decode_code(12), do: "Status-Server"
    defp decode_code(13), do: "Status-Client"
    defp decode_code(x),  do: x
 
    defp decode_payload(ctx) do
      decode_tlv(ctx.rest,[],{1,1}) |> resolve_tlv(ctx)
    end

    defp decode_tlv(<<>>,acc,_), do: Enum.reverse acc
    defp decode_tlv(bin,_,{_,0}), do: bin #not to decode USR style VSAs at all
    defp decode_tlv(bin, acc, {tl,ll}=fmt) when byte_size(bin) > tl+ll do
      tl = tl * 8
      ll = ll * 8
      <<type :: integer-size(tl), length :: integer-size(ll), rest :: binary>> = bin
      length = length - 2
      <<value :: binary-size(length),rest::binary>> = rest
      decode_tlv(rest,[{type, length, value}|acc], fmt)
    end #def decode_tlv/3

    defp resolve_tlv(attrs,ctx) when is_list(attrs) do
      attrs = Enum.map attrs, fn(x)->
        resolve_tlv x,ctx,nil
      end
      Map.put ctx, :attrs, attrs
    end

    #VSA Entry
    defp resolve_tlv({26,len,value}, ctx, nil) do
      type = "Vendor-Specific"
      <<vid::size(32),rest::binary>>=value
      try do
        v = Vendor.by_id vid
        value = case decode_tlv rest,[],v.format do
          bin when is_binary(bin) -> bin
          tlv when is_list(tlv) ->
            Enum.map tlv, fn(x) ->
              resolve_tlv(x,ctx,v.id)
            end
        end
        {{type,v.name},len,value}
      rescue e in EntryNotFoundError ->
        {type,len,value}
      end
    end

    defp resolve_tlv({type,len,value}=tlv, ctx, vendor) do
      try do
        attr = Attribute.by_id vendor,type
        type = attr.name
        if Keyword.has_key? attr.opts, :has_tag do
          <<tag,rest::binary>> = value
          if tag in 0..0x1f do
            value = rest
            type = {type,tag}
          end
        end
        value = value 
                |> decode_value(attr.type)
                |> resolve_value(vendor,attr.id)
                |> decrypt_value(Keyword.get(attr.opts, :encrypt), ctx.auth, ctx.secret)

        {type,len,value}
      rescue e in EntryNotFoundError->
          tlv
      end
    end

    defp decode_value(<<val :: integer-size(8)>>,:byte), do: val
    defp decode_value(<<val :: integer-size(16)>>,:short), do: val
    defp decode_value(<<val :: integer-size(32)>>,:integer), do: val
    defp decode_value(<<val :: integer-size(32)-signed>>,:signed), do: val
    defp decode_value(<<val :: integer-size(32)>>,:date), do: val
    defp decode_value(<<val :: integer-size(64)>>,:ifid), do: val
    defp decode_value(<<a,b,c,d>>,:ipaddr), do: {a,b,c,d}
    defp decode_value(<<bin :: binary-size(16)>>,:ipv6addr) do
      (for <<x::integer-size(16) <-bin >>, do: x) |> :erlang.list_to_tuple
    end
    defp decode_value(bin,_t) do
      bin
    end

    defp resolve_value(val,vid,aid) do
      try do
        v = Value.by_value vid,aid,val
        v.name
      rescue e in EntryNotFoundError ->
        val
      end
    end
    defp decrypt_value(bin,nil,_,_), do: bin
    defp decrypt_value(bin,1,auth,secret) do
      RadiusUtil.decrypt_rfc2865 bin,secret,auth
    end
    defp decrypt_value(bin,2,auth,secret) do
      RadiusUtil.decrypt_rfc2868 bin,secret,auth
    end
    defp decrypt_value(bin,a,_,_) do
      Logger.error "Unknown encrypt type: #{inspect a}"
      bin
    end

    def encode(packet) do
      ctx = Map.from_struct(packet)
      attrs = encode_attrs ctx
      header = encode_header ctx,attrs
      [header,attrs] 
    end

    defp encode_attrs(%{attrs: a}=ctx) do 
      Enum.map a, fn(x) ->
        x|> resolve_attr(ctx) |>(fn(x)-> 
          Logger.debug inspect x
          x
        end).()|> encode_attr
      end
    end

    #back-door for VSAs, encode_vsa could retuen an iolist
    defp encode_attr({26,value}), do: [26,:erlang.iolist_size(value)+2,value]
    defp encode_attr({tag,value}) when is_binary(value) do
      len = byte_size(value) + 2
      if len > 0xff do
        raise "value oversized: #{inspect {tag,value}}"
      end
      <<tag,len,value::binary>>
    end
    defp encode_attr({tag,value}) when is_integer(value) do
      if value > 0xFFFFFFFF do
        Logger.warn "value truncated: #{inspect {tag,value}}"
      end
      <<tag,6,value::integer-size(32)>>
    end
    defp encode_attr({tag,value,attr}) do
      {t,l}=attr.vendor.format
      value = encode_value(value,attr.type)
      length = byte_size(value) + t + l
      ll = l*8
      tl = t*8
      <<tag :: integer-size(tl), length :: integer-size(ll), value :: binary>>
    end

    defp encode_value(val,:byte)    when is_integer(val), do: <<val::size(8)>>
    defp encode_value(val,:short)   when is_integer(val), do: <<val::size(16)>>
    defp encode_value(val,:integer) when is_integer(val), do: <<val::size(32)>>
    defp encode_value(val,:signed)  when is_integer(val), do: <<val::size(32)-signed>>
    defp encode_value(val,:date)    when is_integer(val), do: <<val::size(32)>>
    defp encode_value(val,:ifid)    when is_integer(val), do: <<val::size(64)>>
    defp encode_value({a,b,c,d},:ipaddr), do: <<a,b,c,d>>
    defp encode_value(x,:ipaddr) when is_integer(x), do: <<x::size(32)>>
    defp encode_value(x,:ipv6addr) when is_tuple(x) and tuple_size(x) == 8 do
      for x <- :erlang.tuple_to_list(x), into: "", do: <<x::size(16)>>
    end
    defp encode_value(bin,_), do: bin


    defp resolve_attr({{type,vid},value},ctx) when type=="Vendor-Specific" or type == 26 do
      {26,encode_vsa(vid,value,ctx)}
    end
    defp resolve_attr(tlv,ctx), do: resolve_attr(tlv,ctx,%Vendor{})

    #length is ignored.
    defp resolve_attr({type,_,value},ctx, vendor) do
      resolve_attr({type,value},ctx, vendor)
    end

    defp resolve_attr({type,value},ctx,vendor) do
      case lookup_attr(vendor,type) do
        nil -> {type,value}
        %{type: :integer}=a when is_binary(value) ->
          try do
            v = Value.by_name vendor.name,a.name,value
            {a.id,v.value,a}
          rescue e in EntryNotFoundError->
            raise "Value can not be resolved: #{a.name}: #{value}" 
          end
        a -> {a.id,value,a}
      end
    end

    defp lookup_attr(vendor,type) when is_integer(type) do
      try do
        Attribute.by_id vendor.id,type 
      rescue 
        e in EntryNotFoundError -> nil
      end
    end

    #Raise an error if attr not defined
    defp lookup_attr(_vendor,type) when is_binary(type) do
      Attribute.by_name type 
    end

    defp encode_vsa(vid,value,ctx) when is_binary(value) and is_binary(vid), do: encode_vsa(Vendor.by_name(vid).id,value,ctx)
    defp encode_vsa(vid,value,_) when is_binary(value) and is_integer(vid), do: <<vid::size(32),value>>
    defp encode_vsa(vid,vsa,ctx) when is_tuple(vsa), do: encode_vsa(vid, [vsa], ctx)
    defp encode_vsa(vid,vsa,ctx) when is_binary(vid), do: encode_vsa(Vendor.by_name(vid), vsa, ctx)
    defp encode_vsa(vid,vsa,ctx) when is_integer(vid), do: encode_vsa(Vendor.by_id(vid), vsa, ctx)
    defp encode_vsa(vendor, vsa, ctx) do
      val = Enum.map vsa, fn(x) ->
        x|> resolve_attr(ctx,vendor)|> encode_attr
      end
      [<<vendor.id::size(32)>>|val]
    end

    defp encode_header(ctx,attrs) do
      code = encode_code(ctx.code)
      length = 20 + :erlang.iolist_size attrs
      header = 
            <<code :: integer-size(8),
            ctx.id :: integer-size(8),
            length :: integer-size(16) >>

      hash = :crypto.hash_init(:md5)
              |> :crypto.hash_update(header)
              |> :crypto.hash_update(ctx.auth)
              |> :crypto.hash_update(attrs)
              |> :crypto.hash_update(ctx.secret)
              |> :crypto.hash_final()

      [header,hash]
    end
    #defp encode_code(x) when is_binary(x) do 
    #  x |> String.replace("-","_")
    #    |> String.downcase() 
    #    |> String.to_existing_atom()
    #    |> encode_code()
    #end
    defp encode_code(x) when is_integer(x), do: x
    defp encode_code("Access-Request"), do: 1
    defp encode_code("Access-Accept"), do: 2
    defp encode_code("Access-Reject"), do: 3
    defp encode_code("Access-Challenge"), do: 11
    defp encode_code("Accounting-Request"), do: 4
    defp encode_code("Accounting-Response"), do: 5
    defp encode_code("Status-Server"), do: 12
    defp encode_code("Status-Client"), do: 13
  end #defmodule Packet

  def listen(port) do
    :gen_udp.open(port,[{:active,:false},{:mode,:binary}])
  end

  def recvfrom(sk,secret) when is_binary(secret) do
    recvfrom sk,fn(_,_) -> secret end
  end
  def recvfrom(sk,secret_fn) when is_function(secret_fn) do
    {:ok,{host,port,data}} = :gen_udp.recv sk,5000
    secret = secret_fn.(host,port)
    packet = Packet.decode data,secret
    {:ok,{host,port},packet}
  end

  def sendto(sk,{host,port},packet) do
    data = Packet.encode packet
    :gen_udp.send sk,host,port,data
  end
end

