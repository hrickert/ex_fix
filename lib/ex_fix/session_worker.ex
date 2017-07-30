defmodule ExFix.SessionWorker do
  @moduledoc """
  FIX session worker
  """

  require Logger
  use GenServer
  alias ExFix.SessionRegistry
  alias ExFix.Session
  alias ExFix.Serializer
  alias ExFix.SessionTimer

  @compile {:inline, handle_data: 5}

  defmodule State do
    @moduledoc false
    defstruct name: nil,
      mode: :initiator,
      transport: nil,
      client: nil,
      session: nil,
      log_outgoing_msg: true,
      rx_timer: nil,
      tx_timer: nil
  end

  def start_link(config) do
    # name = {:via, ExFix.Registry, {:ex_fix_session, config.name}}
    name = :"ex_fix_session_#{config.name}"
    GenServer.start_link(__MODULE__, [config], name: name)
  end

  def send_message(fix_session, msg_type, fields) when is_binary(fix_session) do
    # name = {:via, ExFix.Registry, {:ex_fix_session, fix_session}}
    name = :"ex_fix_session_#{fix_session}"
    GenServer.call(name, {:send_message, msg_type, fields})
  end

  def stop(fix_session) do
    # name = {:via, ExFix.Registry, {:ex_fix_session, fix_session}}
    name = :"ex_fix_session_#{fix_session}"
    GenServer.call(name, :stop)
  end


  ##
  ## GenServer callbacks
  ##

  def init([config]) do
    Logger.debug fn -> "SessionWorker.init() - config: #{inspect config}" end
    action = SessionRegistry.session_on_init(config.name)
    send(self(), {:init, action, config})
    {:ok, %State{name: config.name, mode: config.mode,
      log_outgoing_msg: config.log_outgoing_msg}}
  end

  def handle_info({:timeout, timer_name}, %State{name: fix_session_name,
      transport: transport, client: client, session: session,
      log_outgoing_msg: log_outgoing_msg, tx_timer: tx_timer} = state) do
    {:ok, msgs_to_send, session} = Session.handle_timeout(session, timer_name)
    do_send_messages(transport, client, msgs_to_send, fix_session_name,
      log_outgoing_msg, tx_timer)
    {:noreply, %State{state | session: session}}
  end

  def handle_info({:ssl, _socket, data}, %State{transport: transport, client: client,
      session: session, rx_timer: rx_timer} = state) do
    handle_data(data, transport, client, session, state)
  end

  def handle_info({:tcp, _socket, data}, %State{transport: transport, client: client,
      session: session, rx_timer: rx_timer} = state) do
    handle_data(data, transport, client, session, state)
  end

  def handle_info({:init, action, config}, %State{name: fix_session_name} = state) do
    case action do
      :ok ->
        connect_and_send_logon(config, state)
      :wait_to_reconnect ->
        Logger.info "Waiting #{config.reconnect_interval} seconds to reconnect..."
        Process.sleep(config.reconnect_interval * 1_000)
        connect_and_send_logon(config, state)
      {:error, reason} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:ssl_closed, _socket}, state) do
    {:stop, :closed, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :closed, state}
  end

  def handle_call({:send_message, msg_type, fields}, _from, %State{name: name, transport: transport,
      client: client, session: session, log_outgoing_msg: log_outgoing_msg, tx_timer: tx_timer} = state) do
    {:ok, msgs, session} = Session.send_message(session, msg_type, fields)
    do_send_messages(transport, client, msgs, name, log_outgoing_msg, tx_timer)
    {:reply, :ok, %State{state | session: session}}
  end

  def handle_call(:stop, _from, %State{transport: transport, client: client, session: session} = state) do
    # TODO logout
    transport.close(client)
    {:reply, :ok, state}
  end

  def terminate(:econnrefused, %State{name: fix_session_name} = _state) do
    SessionRegistry.session_update_status(fix_session_name, :reconnecting)
    :ok
  end
  def terminate(:closed, %State{name: fix_session_name} = _state) do
    SessionRegistry.session_update_status(fix_session_name, :reconnecting)
    :ok
  end
  def terminate(reason, _state) do
    Logger.warn "terminate: #{inspect reason}"
    :ok
  end


  ##
  ## Private functions
  ##

  defp handle_data(data, transport, client, session, %State{name: name,
      log_outgoing_msg: log_outgoing_msg, tx_timer: tx_timer, rx_timer: rx_timer} = state) do
    case Session.handle_incoming_data(session, data) do
      {:ok, [], session2} ->
        unless rx_timer do
          rx_timer = SessionTimer.setup_timer(:rx, round(session.config.heart_bt_int * 1.2))
          SessionRegistry.session_update_status(name, :connected)
        end
        send(rx_timer, :msg)
        {:noreply, %State{state | session: session2, rx_timer: rx_timer}}
      {:ok, msgs_to_send, session2} ->
        send(rx_timer, :msg)
        do_send_messages(transport, client, msgs_to_send, name,
          state.log_outgoing_msg, state.tx_timer)
        {:noreply, %State{state | session: session2}}
      {:resend, msgs_to_send, session2} ->
        send(rx_timer, :msg)
        do_send_messages(transport, client, msgs_to_send, name,
          state.log_outgoing_msg, state.tx_timer, true)
        {:noreply, %State{state | session: session2}}
      {:logout, msgs_to_send, session2} ->
        send(rx_timer, :msg)
        ## TODO start logout process
        do_send_messages(transport, client, msgs_to_send, state.name,
          state.log_outgoing_msg, state.tx_timer)
        {:noreply, %State{state | session: session2}}
    end
  end

  defp do_send_messages(transport, client, msgs_to_send, fix_session, log, tx_timer,
      resend \\ false) do
    for msg <- msgs_to_send do
      data = Serializer.serialize(msg, DateTime.utc_now(), resend)
      if log do
        Logger.info "[fix.outgoing] [#{fix_session}] " <>
          :unicode.characters_to_binary(data, :latin1, :utf8)
      end
      transport.send(client, data)
      send(tx_timer, :msg)
      ## TODO store in output buffer
    end
    :ok
  end

  defp connect_and_send_logon(config, %State{name: fix_session_name,
      log_outgoing_msg: log_outgoing_msg} = state) do
    Logger.debug fn -> "Starting FIX session: [#{fix_session_name}]" end
    {:ok, session} = Session.init(config)
    {:ok, msgs_to_send, session} = Session.session_start(session)
    %Session{config: config} = session
    host = config.socket_connect_host
    port = config.socket_connect_port
    Logger.debug fn -> "[#{fix_session_name}] Trying to connect to #{host}:#{port}..." end
    str_host = String.to_char_list(host)
    options = [mode: :binary] ++ config.connection_options
    {transport, result} = case config.socket_use_ssl do
      true -> {:ssl, :ssl.connect(str_host, port, options)}
      false -> {:gen_tcp, :gen_tcp.connect(str_host, port, options)}
    end
    case result do
      {:ok, client} ->
        tx_timer = SessionTimer.setup_timer(:tx, session.config.heart_bt_int)
        do_send_messages(transport, client, msgs_to_send, fix_session_name,
          log_outgoing_msg, tx_timer)
        {:noreply, %State{state | transport: transport, client: client,
          session: session, tx_timer: tx_timer}}
      {:error, reason} ->
        Logger.error "Cannot open socket: #{inspect reason}"
        {:stop, reason, state}
    end
  end
end