package fo.dronedirector.scanforgepro.live

import android.opengl.GLES20
import android.opengl.Matrix
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Draws Auto scan's live surface as soft round points over the camera image,
 * with a glowing light sweep that runs over the part being scanned.
 */
class SurfelRenderer {
    private var program = 0
    private var aPos = 0
    private var aCol = 0
    private var aKind = 0
    private var uMvp = 0
    private var uView = 0
    private var uScale = 0
    private var uTime = 0
    private var uSweep = 0
    private val vbo = IntArray(1)
    private var count = 0
    private val mvp = FloatArray(16)

    fun create() {
        val vs = compile(GLES20.GL_VERTEX_SHADER, """
            uniform mat4 u_Mvp;
            uniform mat4 u_View;
            uniform float u_Scale;
            uniform float u_Time;
            uniform vec3 u_Sweep;    // sweep: bottom y, top y, on (1/0)
            attribute vec3 a_Pos;
            attribute vec4 a_Col;
            attribute float a_Kind;
            varying vec4 v_Col;
            varying float v_Glow;
            void main() {
                vec4 p = u_Mvp * vec4(a_Pos, 1.0);
                gl_Position = p;
                float z = max(0.05, -(u_View * vec4(a_Pos, 1.0)).z);
                // light band moving up over the object, plus a soft shimmer
                float h = max(0.02, u_Sweep.y - u_Sweep.x);
                float s = u_Sweep.x + fract(u_Time * 0.45) * (h + 0.10) - 0.05;
                float q = (a_Pos.y - s) / (0.035 + 0.06 * h);
                float band = exp(-q * q) * u_Sweep.z;
                float inView = step(abs(p.x / p.w), 0.6) * step(abs(p.y / p.w), 0.6);
                float shimmer = 0.5 + 0.5 * sin(u_Time * 6.0 + a_Pos.x * 60.0 + a_Pos.z * 47.0);
                v_Glow = (band * (0.6 + 0.4 * inView) + 0.12 * inView * shimmer) * (1.0 - a_Kind);
                v_Col = a_Col;
                gl_PointSize = clamp(u_Scale / z * (1.0 + 0.6 * band), 2.0, 28.0);
            }
        """.trimIndent())
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, """
            precision mediump float;
            varying vec4 v_Col;
            varying float v_Glow;
            void main() {
                vec2 c = gl_PointCoord - vec2(0.5);
                float r = dot(c, c);
                if (r > 0.25) discard;
                float edge = 1.0 - smoothstep(0.12, 0.25, r);
                vec3 glowCol = vec3(0.45, 0.95, 1.0);
                vec3 col = mix(v_Col.rgb, glowCol, clamp(v_Glow, 0.0, 0.85)) + glowCol * v_Glow * 0.35;
                gl_FragColor = vec4(col, v_Col.a * edge);
            }
        """.trimIndent())
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glLinkProgram(program)
        aPos = GLES20.glGetAttribLocation(program, "a_Pos")
        aCol = GLES20.glGetAttribLocation(program, "a_Col")
        aKind = GLES20.glGetAttribLocation(program, "a_Kind")
        uMvp = GLES20.glGetUniformLocation(program, "u_Mvp")
        uView = GLES20.glGetUniformLocation(program, "u_View")
        uScale = GLES20.glGetUniformLocation(program, "u_Scale")
        uTime = GLES20.glGetUniformLocation(program, "u_Time")
        uSweep = GLES20.glGetUniformLocation(program, "u_Sweep")
        GLES20.glGenBuffers(1, vbo, 0)
    }

    /** Uploads points (8 floats each, see SparseTsdf.surfels). GL thread only. */
    fun upload(data: FloatArray) {
        val buf = ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        buf.put(data)
        buf.position(0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo[0])
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, data.size * 4, buf, GLES20.GL_DYNAMIC_DRAW)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        count = data.size / 8
    }

    fun draw(view: FloatArray, proj: FloatArray, viewH: Int, voxel: Float, timeSec: Float,
             sweepBottom: Float, sweepTop: Float, sweepOn: Boolean) {
        if (count == 0 || program == 0) return
        Matrix.multiplyMM(mvp, 0, proj, 0, view, 0)
        GLES20.glUseProgram(program)
        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0)
        GLES20.glUniformMatrix4fv(uView, 1, false, view, 0)
        // point size in pixels for one voxel at 1 m, a little larger so points touch
        GLES20.glUniform1f(uScale, proj[5] * viewH * 0.5f * voxel * 1.8f)
        GLES20.glUniform1f(uTime, timeSec)
        GLES20.glUniform3f(uSweep, sweepBottom, sweepTop, if (sweepOn) 1f else 0f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthMask(true)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo[0])
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, 32, 0)
        GLES20.glVertexAttribPointer(aCol, 4, GLES20.GL_FLOAT, false, 32, 12)
        GLES20.glVertexAttribPointer(aKind, 1, GLES20.GL_FLOAT, false, 32, 28)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glEnableVertexAttribArray(aCol)
        GLES20.glEnableVertexAttribArray(aKind)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, count)
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aCol)
        GLES20.glDisableVertexAttribArray(aKind)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        return s
    }
}
