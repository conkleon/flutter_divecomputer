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
import java.util.concurrent.Executors

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
  private var pendingPermissionResult: MethodChannel.Result? = null

  private var eventSink: EventChannel.EventSink? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val io = Executors.newSingleThreadExecutor()

  private var socket: BluetoothSocket? = null
  private var readerThread: Thread? = null

  private val adapter: BluetoothAdapter?
    get() = (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

  // --- FlutterPlugin ---

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
    methodChannel.setMethodCallHandler(this)
    eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
    eventChannel.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    closeSocket()
    io.shutdownNow()
  }

  // --- ActivityAware ---

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addRequestPermissionsResultListener(this)
  }
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
      onAttachedToActivity(binding)
  override fun onDetachedFromActivityForConfigChanges() { activity = null }
  override fun onDetachedFromActivity() { activity = null }

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
        val list = a.bondedDevices.map { mapOf("name" to (it.name ?: ""), "address" to it.address) }
        result.success(list)
      }

      "connect" -> {
        val address = call.argument<String>("address")
        if (address == null) { result.error("bad_args", "address required", null); return }
        if (!hasConnectPermission()) {
          result.error("permission_denied", "BLUETOOTH_CONNECT not granted", null); return
        }
        io.execute {
          try {
            closeSocket()
            val a = adapter ?: throw IllegalStateException("No Bluetooth adapter")
            a.cancelDiscovery()
            val s = a.getRemoteDevice(address).createRfcommSocketToServiceRecord(SPP_UUID)
            s.connect() // blocks ~12s, throws IOException on failure
            socket = s
            startReader(s)
            mainHandler.post { result.success(null) }
          } catch (e: Exception) {
            closeSocket()
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
    val t = Thread {
      val buf = ByteArray(4096)
      try {
        while (!Thread.currentThread().isInterrupted) {
          val n = s.inputStream.read(buf)
          if (n < 0) break
          if (n > 0) {
            val chunk = buf.copyOf(n)
            mainHandler.post { eventSink?.success(chunk) }
          }
        }
      } catch (_: Exception) {
        // fall through to endOfStream
      }
      mainHandler.post { eventSink?.endOfStream() }
    }
    t.isDaemon = true
    readerThread = t
    t.start()
  }

  private fun closeSocket() {
    readerThread?.interrupt()
    readerThread = null
    try { socket?.close() } catch (_: Exception) {}
    socket = null
  }
}
