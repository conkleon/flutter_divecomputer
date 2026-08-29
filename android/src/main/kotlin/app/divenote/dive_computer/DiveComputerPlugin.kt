package app.divenote.dive_computer

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger

private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
private const val METHOD_CHANNEL = "app.divenote.dive_computer/rfcomm"
private const val EVENT_CHANNEL = "app.divenote.dive_computer/rfcomm/inbound"
private const val PERM_REQUEST_CODE = 0xB7

class DiveComputerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PluginRegistry.RequestPermissionsResultListener {

  private lateinit var appContext: Context
  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel

  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var pendingPermissionResult: MethodChannel.Result? = null

  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  // Single-threaded executor: every socket-state mutation is serialized here.
  // `var` so it can be recreated after onDetachedFromEngine shuts it down
  // (add-to-app / restart can re-attach a new engine to this same instance).
  private var io: ExecutorService = Executors.newSingleThreadExecutor()

  // Mutated on `io`, read on the main thread (`write`) -> must be @Volatile.
  @Volatile private var socket: BluetoothSocket? = null
  @Volatile private var readerThread: Thread? = null
  // The socket currently inside a blocking connect(). Closed directly (from any
  // thread) by closeSocket() to abort an in-flight connect.
  @Volatile private var pendingSocket: BluetoothSocket? = null
  // Bumped by every closeSocket(); an in-flight connect that sees its captured
  // value change must drop the socket instead of adopting it.
  private val connectGen = AtomicInteger(0)

  private val adapter: BluetoothAdapter?
    get() = (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

  // --- FlutterPlugin ---

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    if (io.isShutdown) io = Executors.newSingleThreadExecutor()
    methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
    methodChannel.setMethodCallHandler(this)
    eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
    eventChannel.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    closeSocket()
    // shutdown() (not shutdownNow()) lets the closeSocket() task above run.
    io.shutdown()
  }

  // --- ActivityAware ---

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    activity = binding.activity
    binding.addRequestPermissionsResultListener(this)
  }
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
      onAttachedToActivity(binding)
  override fun onDetachedFromActivityForConfigChanges() = detachActivity()
  override fun onDetachedFromActivity() = detachActivity()

  private fun detachActivity() {
    activityBinding?.removeRequestPermissionsResultListener(this)
    activityBinding = null
    activity = null
  }

  // --- permissions ---

  private fun hasConnectPermission(): Boolean =
      Build.VERSION.SDK_INT < 31 ||
          ActivityCompat.checkSelfPermission(appContext, Manifest.permission.BLUETOOTH_CONNECT) ==
              PackageManager.PERMISSION_GRANTED

  override fun onRequestPermissionsResult(
      requestCode: Int, permissions: Array<out String>, grantResults: IntArray
  ): Boolean {
    if (requestCode != PERM_REQUEST_CODE) return false
    val granted = grantResults.isNotEmpty() &&
        grantResults[0] == PackageManager.PERMISSION_GRANTED
    pendingPermissionResult?.success(granted)
    pendingPermissionResult = null
    return true
  }

  // --- MethodChannel ---

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "requestPermissions" -> {
        if (Build.VERSION.SDK_INT < 31 || hasConnectPermission()) {
          result.success(true); return
        }
        val act = activity
        if (act == null) { result.success(false); return }
        if (pendingPermissionResult != null) {
          result.error(
              "permission_request_pending",
              "a permission request is already in progress", null)
          return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            act, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERM_REQUEST_CODE)
      }

      "bondedDevices" -> {
        if (!hasConnectPermission()) {
          result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null); return
        }
        val a = adapter
        if (a == null) { result.error("no_adapter", "No Bluetooth adapter", null); return }
        if (!a.isEnabled) { result.error("bluetooth_off", "Bluetooth is turned off", null); return }
        // getBondedDevices() returns null when the adapter is disabled.
        val bonded = a.bondedDevices ?: emptySet()
        val list = bonded.map { mapOf("name" to (it.name ?: ""), "address" to it.address) }
        result.success(list)
      }

      "connect" -> {
        val address = call.argument<String>("address")
        if (address == null) { result.error("bad_args", "address required", null); return }
        if (!hasConnectPermission()) {
          result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null); return
        }
        io.execute {
          closeSocketNow()
          val myGen = connectGen.incrementAndGet()
          try {
            val a = adapter ?: throw IllegalStateException("No Bluetooth adapter")
            // Needs BLUETOOTH_SCAN on API >= 31, which the manifest deliberately
            // does not declare. Discovery isn't running anyway -> ignore.
            try { a.cancelDiscovery() } catch (e: SecurityException) { /* no BLUETOOTH_SCAN */ }
            val s = a.getRemoteDevice(address).createRfcommSocketToServiceRecord(SPP_UUID)
            pendingSocket = s
            s.connect() // blocks ~12s, throws IOException on failure
            if (connectGen.get() != myGen) {
              // A disconnect() arrived during connect(): drop this socket.
              pendingSocket = null
              try { s.close() } catch (_: Exception) {}
              mainHandler.post {
                result.error("connect_failed", "disconnected during connect", null)
              }
              return@execute
            }
            pendingSocket = null
            socket = s
            startReader(s)
            mainHandler.post { result.success(null) }
          } catch (e: Exception) {
            pendingSocket = null
            closeSocketNow()
            mainHandler.post { result.error("connect_failed", e.message, null) }
          }
        }
      }

      "write" -> {
        val bytes = call.argument<ByteArray>("bytes")
        val s = socket
        if (bytes == null) { result.error("bad_args", "bytes required", null); return }
        if (s == null) { result.error("not_connected", "No RFCOMM socket", null); return }
        io.execute {
          try {
            synchronized(s) { s.outputStream.write(bytes); s.outputStream.flush() }
            mainHandler.post { result.success(null) }
          } catch (e: Exception) {
            mainHandler.post { result.error("write_failed", e.message, null) }
          }
        }
      }

      "disconnect" -> { closeSocket(); result.success(null) }

      else -> result.notImplemented()
    }
  }

  // --- EventChannel ---

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
  override fun onCancel(arguments: Any?) { eventSink = null }

  private fun startReader(s: BluetoothSocket) {
    // Pin this reader to the connection generation it belongs to. A stale
    // reader from a previous download (its socket closed, connectGen bumped by
    // closeSocket()) must not deliver leftover bytes or a spurious
    // endOfStream to the NEXT download's eventSink.
    val myGen = connectGen.get()
    val t = Thread {
      val buf = ByteArray(4096)
      try {
        while (!Thread.currentThread().isInterrupted) {
          val n = s.inputStream.read(buf)
          if (n < 0) break
          if (n > 0) {
            val chunk = buf.copyOf(n)
            mainHandler.post { if (connectGen.get() == myGen) eventSink?.success(chunk) }
          }
        }
      } catch (_: Exception) {
        // fall through to endOfStream
      }
      mainHandler.post { if (connectGen.get() == myGen) eventSink?.endOfStream() }
    }
    t.isDaemon = true
    readerThread = t
    t.start()
  }

  /**
   * Aborts any in-flight connect immediately (BluetoothSocket.close() is safe
   * from another thread and unblocks a blocking connect()), invalidates the
   * current connect generation, then serializes the rest of the teardown on
   * the `io` thread.
   */
  private fun closeSocket() {
    try { pendingSocket?.close() } catch (_: Exception) {}
    connectGen.incrementAndGet()
    try { io.execute { closeSocketNow() } } catch (_: RejectedExecutionException) {}
  }

  /** Full socket-state teardown. Must run on the `io` thread. */
  private fun closeSocketNow() {
    readerThread?.interrupt()
    readerThread = null
    try { pendingSocket?.close() } catch (_: Exception) {}
    pendingSocket = null
    try { socket?.close() } catch (_: Exception) {}
    socket = null
  }
}
