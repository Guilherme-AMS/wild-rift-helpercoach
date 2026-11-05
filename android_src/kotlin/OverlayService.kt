package com.riftHelper.wildrift_helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.min

/**
 * Bolha flutuante sobre o jogo. A gravação de tela só liga quando o
 * usuário toca em "Ler draft" e desliga sozinha ao terminar o draft.
 */
class OverlayService : Service() {

    companion object {
        const val ACTION_START = "rift.START"
        const val ACTION_STOP = "rift.STOP"
        const val ACTION_CAPTURE_RESULT = "rift.CAPTURE_RESULT"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL_ID = "rift_overlay"
        private const val NOTIF_ID = 4242
        private const val FRAME_INTERVAL_MS = 1200L
        private const val CAPTURE_TIMEOUT_MS = 4 * 60 * 1000L

        @Volatile var running = false
        @Volatile var pendingJson: String? = null

        private val LANES = listOf("Baron", "Jungle", "Mid", "Duo", "Support")
        private val LANE_LABELS = mapOf(
            "Baron" to "Barão", "Jungle" to "Selva", "Mid" to "Meio",
            "Duo" to "Dragão", "Support" to "Suporte"
        )
    }

    // ------------------------------------------------------------ dados

    private class Stat(
        val name: String, val lane: String,
        val win: Double, val pick: Double, val ban: Double
    ) {
        var score = 0.0
        var tier = "B"
    }

    private val stats = mutableListOf<Stat>()
    private val aliasToName = HashMap<String, String>()

    private fun loadData(json: String) {
        stats.clear()
        aliasToName.clear()
        val arr = JSONObject(json).getJSONArray("stats")
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            stats.add(
                Stat(
                    o.getString("name"), o.getString("lane"),
                    o.getDouble("win"), o.getDouble("pick"), o.getDouble("ban")
                )
            )
        }
        for (s in stats) s.score = (s.win - 50) * 2 + s.pick * 0.25 + s.ban * 0.05
        for (lane in LANES) {
            val list = byLane(lane)
            val n = list.size
            list.forEachIndexed { i, s ->
                val p = if (n <= 1) 0.0 else i.toDouble() / (n - 1)
                s.tier = when {
                    p < 0.10 -> "S"
                    p < 0.30 -> "A"
                    p < 0.65 -> "B"
                    p < 0.90 -> "C"
                    else -> "D"
                }
            }
        }
        for (name in stats.map { it.name }.toSet()) {
            aliasToName[norm(name)] = name
            val first = name.split(" ", "&", ".", "'").firstOrNull { it.isNotBlank() }
            if (first != null && first.length >= 4 && first.length < name.length) {
                aliasToName.putIfAbsent(norm(first), name)
            }
        }
    }

    private fun loadBundled(): String =
        assets.open("flutter_assets/assets/meta.json").bufferedReader().use { it.readText() }

    private fun byLane(lane: String) =
        stats.filter { it.lane == lane }.sortedByDescending { it.score }

    private fun mainStat(name: String) =
        stats.filter { it.name == name }.maxByOrNull { it.pick }

    private fun norm(s: String) = s.lowercase().filter { it.isLetter() }

    private fun levenshtein(a: String, b: String): Int {
        val dp = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            var prev = dp[0]
            dp[0] = i
            for (j in 1..b.length) {
                val tmp = dp[j]
                dp[j] = minOf(
                    dp[j] + 1, dp[j - 1] + 1,
                    prev + if (a[i - 1] == b[j - 1]) 0 else 1
                )
                prev = tmp
            }
        }
        return dp[b.length]
    }

    private fun matchChampion(raw: String): String? {
        val s = norm(raw)
        if (s.length < 3 || s.length > 20) return null
        aliasToName[s]?.let { return it }
        if (s.length < 5) return null
        val maxDist = if (s.length >= 8) 2 else 1
        var best: String? = null
        var bestD = Int.MAX_VALUE
        for ((alias, name) in aliasToName) {
            if (abs(alias.length - s.length) > maxDist) continue
            val d = levenshtein(s, alias)
            if (d < bestD) { bestD = d; best = name }
        }
        return if (bestD <= maxDist) best else null
    }

    // ------------------------------------------------------------ estado do draft

    private var allies = listOf<String>()
    private var enemies = listOf<String>()
    private var myLane = "Mid"
    private var swapSides = false

    // ------------------------------------------------------------ captura

    private val handler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var capW = 0
    private var capH = 0
    private var capturing = false
    private var busy = false
    private var completeFrames = 0
    private var captureStartedAt = 0L
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    private val frameLoop = object : Runnable {
        override fun run() {
            if (!capturing) return
            if (System.currentTimeMillis() - captureStartedAt > CAPTURE_TIMEOUT_MS) {
                stopCapture("Tempo esgotado, gravação desligada")
                return
            }
            grabFrame()
            handler.postDelayed(this, FRAME_INTERVAL_MS)
        }
    }

    private fun startCapture(resultCode: Int, data: Intent) {
        goForeground(true)
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = try {
            mpm.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            null
        }
        if (mp == null) {
            goForeground(false)
            setStatus("Não foi possível iniciar a leitura")
            return
        }
        projection = mp
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                handler.post { if (capturing) stopCapture("Leitura encerrada pelo sistema") }
            }
        }, handler)

        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(dm)
        val scale = min(1.0, 1600.0 / maxOf(dm.widthPixels, dm.heightPixels))
        capW = (dm.widthPixels * scale).toInt()
        capH = (dm.heightPixels * scale).toInt()
        val r = ImageReader.newInstance(capW, capH, PixelFormat.RGBA_8888, 2)
        reader = r
        virtualDisplay = mp.createVirtualDisplay(
            "rift-draft", capW, capH, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler
        )
        capturing = true
        busy = false
        completeFrames = 0
        captureStartedAt = System.currentTimeMillis()
        setStatus("Lendo o draft…")
        refreshPanel()
        handler.postDelayed(frameLoop, 600)
    }

    private fun stopCapture(message: String) {
        capturing = false
        handler.removeCallbacks(frameLoop)
        try { virtualDisplay?.release() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        virtualDisplay = null
        reader = null
        projection = null
        if (running) goForeground(false)
        setStatus(message)
        refreshPanel()
    }

    private fun grabFrame() {
        if (busy) return
        val r = reader ?: return
        val image = try { r.acquireLatestImage() } catch (e: Exception) { null } ?: return
        val bitmap: Bitmap
        try {
            val plane = image.planes[0]
            val rowPadding = plane.rowStride - plane.pixelStride * capW
            val full = Bitmap.createBitmap(
                capW + rowPadding / plane.pixelStride, capH, Bitmap.Config.ARGB_8888
            )
            full.copyPixelsFromBuffer(plane.buffer)
            bitmap = if (full.width != capW) {
                Bitmap.createBitmap(full, 0, 0, capW, capH).also { full.recycle() }
            } else full
        } catch (e: Exception) {
            return
        } finally {
            image.close()
        }
        busy = true
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { text ->
                val left = LinkedHashSet<String>()
                val right = LinkedHashSet<String>()
                val w = bitmap.width.toFloat()
                for (block in text.textBlocks) {
                    for (line in block.lines) {
                        val box = line.boundingBox ?: continue
                        val cx = box.exactCenterX() / w
                        // Colunas dos jogadores ficam nas laterais; o centro é a grade de campeões.
                        if (cx > 0.32f && cx < 0.68f) continue
                        val found = matchChampion(line.text)
                            ?: line.elements.firstNotNullOfOrNull { matchChampion(it.text) }
                            ?: continue
                        if (cx <= 0.32f) left.add(found) else right.add(found)
                    }
                }
                onDetections(left.toList(), right.toList())
            }
            .addOnCompleteListener {
                busy = false
                bitmap.recycle()
            }
    }

    private fun onDetections(left: List<String>, right: List<String>) {
        if (!capturing) return
        var a = (if (swapSides) right else left).take(5)
        val e = (if (swapSides) left else right).filter { it !in a }.take(5)
        a = a.take(5)
        var changed = false
        if (a.isNotEmpty() && a.size >= allies.size && a != allies) { allies = a; changed = true }
        if (e.isNotEmpty() && e.size >= enemies.size && e != enemies) { enemies = e; changed = true }
        if (changed) refreshPanel()
        if (allies.size == 5 && enemies.size == 5) {
            completeFrames++
            if (completeFrames >= 2) stopCapture("Draft completo, gravação desligada")
        } else {
            completeFrames = 0
            setStatus("Lendo o draft… ${allies.size + enemies.size}/10")
        }
    }

    // ------------------------------------------------------------ overlay

    private lateinit var windowManager: WindowManager
    private var bubble: View? = null
    private var panel: View? = null
    private lateinit var bubbleParams: WindowManager.LayoutParams
    private var tvStatus: TextView? = null
    private var tvAllies: TextView? = null
    private var tvEnemies: TextView? = null
    private var tvSuggest: TextView? = null
    private var tvThreats: TextView? = null
    private var btnCapture: Button? = null
    private val laneButtons = mutableMapOf<String, Button>()
    private var statusText = "Toque em Ler draft na seleção de campeões"

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
    ).toInt()

    private fun overlayType() =
        if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

    private fun showBubble() {
        if (bubble != null) return
        val size = dp(52)
        val tv = TextView(this).apply {
            text = "RH"
            gravity = Gravity.CENTER
            setTextColor(Color.BLACK)
            typeface = Typeface.DEFAULT_BOLD
            textSize = 16f
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#00BFA5"))
                setStroke(dp(2), Color.WHITE)
            }
            alpha = 0.92f
        }
        bubbleParams = WindowManager.LayoutParams(
            size, size, overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(8)
            y = dp(120)
        }
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        tv.setOnTouchListener { v, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.rawX; downY = ev.rawY
                    startX = bubbleParams.x; startY = bubbleParams.y
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downX
                    val dy = ev.rawY - downY
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) moved = true
                    if (moved) {
                        bubbleParams.x = startX + dx.toInt()
                        bubbleParams.y = startY + dy.toInt()
                        windowManager.updateViewLayout(v, bubbleParams)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        if (ev.eventTime - ev.downTime > 700) stopSelfFully() else togglePanel()
                    }
                    true
                }
                else -> false
            }
        }
        windowManager.addView(tv, bubbleParams)
        bubble = tv
    }

    private fun togglePanel() {
        if (panel != null) hidePanel() else showPanel()
    }

    private fun smallButton(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        textSize = 12f
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = 0
        setPadding(dp(10), dp(6), dp(10), dp(6))
        setOnClickListener { onClick() }
    }

    private fun label(sizeSp: Float, bold: Boolean = false, color: Int = Color.WHITE) =
        TextView(this).apply {
            textSize = sizeSp
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, dp(2))
        }

    private fun showPanel() {
        if (panel != null) return
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(Color.parseColor("#EE15191E"))
                setStroke(dp(1), Color.parseColor("#3300BFA5"))
            }
        }
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        header.addView(label(15f, true, Color.parseColor("#00BFA5")).apply { text = "Rift Helper" },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(smallButton("✕") { hidePanel() })
        root.addView(header)

        tvStatus = label(11f, color = Color.parseColor("#B0BEC5"))
        root.addView(tvStatus)

        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        btnCapture = smallButton("▶ Ler draft") {
            if (capturing) stopCapture("Gravação desligada") else requestCapture()
        }
        actions.addView(btnCapture)
        actions.addView(smallButton("⇄ Lados") {
            swapSides = !swapSides
            val t = allies; allies = enemies; enemies = t
            refreshPanel()
        })
        actions.addView(smallButton("Limpar") {
            allies = emptyList(); enemies = emptyList(); refreshPanel()
        })
        root.addView(actions)

        val lanes = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        laneButtons.clear()
        for (l in LANES) {
            val b = smallButton(LANE_LABELS[l]!!.take(3)) { myLane = l; refreshPanel() }
            laneButtons[l] = b
            lanes.addView(b)
        }
        root.addView(lanes)

        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        tvAllies = label(12f); content.addView(tvAllies)
        tvEnemies = label(12f); content.addView(tvEnemies)
        tvSuggest = label(12f); content.addView(tvSuggest)
        tvThreats = label(12f); content.addView(tvThreats)
        val scroll = ScrollView(this).apply { addView(content) }
        root.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        val screenH = resources.displayMetrics.heightPixels
        val params = WindowManager.LayoutParams(
            dp(310), min(dp(340), (screenH * 0.9).toInt()), overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = bubbleParams.x + dp(60)
            y = maxOf(0, min(bubbleParams.y, screenH - dp(340)))
        }
        windowManager.addView(root, params)
        panel = root
        refreshPanel()
    }

    private fun hidePanel() {
        panel?.let { try { windowManager.removeView(it) } catch (_: Exception) {} }
        panel = null
        tvStatus = null; tvAllies = null; tvEnemies = null; tvSuggest = null; tvThreats = null
        btnCapture = null
        laneButtons.clear()
    }

    private fun setStatus(msg: String) {
        statusText = msg
        tvStatus?.text = msg
    }

    private fun tierOf(name: String) = mainStat(name)?.tier ?: "?"

    private fun refreshPanel() {
        if (panel == null) return
        tvStatus?.text = statusText
        btnCapture?.text = if (capturing) "■ Parar" else "▶ Ler draft"
        for ((l, b) in laneButtons) {
            b.setTextColor(if (l == myLane) Color.parseColor("#00BFA5") else Color.DKGRAY)
            b.typeface = if (l == myLane) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        tvAllies?.text = "Aliados: " +
            (if (allies.isEmpty()) "—" else allies.joinToString(", ") { "$it (${tierOf(it)})" })
        tvEnemies?.text = "Inimigos: " +
            (if (enemies.isEmpty()) "—" else enemies.joinToString(", ") { "$it (${tierOf(it)})" })

        val used = (allies + enemies).toSet()
        val picks = byLane(myLane).filter { it.name !in used }.take(5)
        tvSuggest?.text = buildString {
            append("Melhores escolhas · ${LANE_LABELS[myLane]}\n")
            picks.forEachIndexed { i, s ->
                append("${i + 1}. ${s.name}  ${s.tier} · ${"%.1f".format(s.win)}%\n")
            }
            if (picks.isEmpty()) append("Nenhuma opção livre")
        }.trimEnd()

        val threats = enemies.mapNotNull { mainStat(it) }.sortedByDescending { it.score }
        tvThreats?.text = if (threats.isEmpty()) "" else buildString {
            append("Ameaças\n")
            for (s in threats) {
                append("${s.name} · ${LANE_LABELS[s.lane]} · ${s.tier} · ${"%.1f".format(s.win)}%\n")
            }
        }.trimEnd()
    }

    private fun requestCapture() {
        setStatus("Autorize a gravação (escolha a tela inteira)")
        val i = Intent(this, CaptureActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        try {
            startActivity(i)
        } catch (e: Exception) {
            setStatus("Não foi possível pedir a permissão de gravação")
        }
    }

    // ------------------------------------------------------------ serviço

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Bolha do Rift Helper", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, OverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Rift Helper ativo")
            .setContentText(if (capturing || projection != null) "Lendo o draft" else "Bolha sobre o jogo")
            .setOngoing(true)
            .addAction(@Suppress("DEPRECATION") Notification.Action.Builder(0, "Fechar", stopIntent).build())
            .build()
    }

    private fun goForeground(withProjection: Boolean) {
        val n = buildNotification()
        when {
            Build.VERSION.SDK_INT >= 34 -> {
                val type = if (withProjection)
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                else ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                startForeground(NOTIF_ID, n, type)
            }
            Build.VERSION.SDK_INT >= 29 && withProjection ->
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            else -> startForeground(NOTIF_ID, n)
        }
    }

    private fun stopSelfFully() {
        if (capturing) stopCapture("")
        hidePanel()
        bubble?.let { try { windowManager.removeView(it) } catch (_: Exception) {} }
        bubble = null
        running = false
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelfFully()
                return START_NOT_STICKY
            }
            ACTION_CAPTURE_RESULT -> {
                val code = intent.getIntExtra(EXTRA_CODE, 0)
                val data: Intent? = if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_DATA)
                if (data != null && running) startCapture(code, data)
            }
            else -> {
                goForeground(false)
                if (stats.isEmpty() || pendingJson != null) {
                    try {
                        loadData(pendingJson ?: loadBundled())
                    } catch (e: Exception) {
                        loadData(loadBundled())
                    }
                    pendingJson = null
                }
                running = true
                showBubble()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (capturing) stopCapture("")
        hidePanel()
        bubble?.let { try { windowManager.removeView(it) } catch (_: Exception) {} }
        bubble = null
        running = false
        try { recognizer.close() } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
