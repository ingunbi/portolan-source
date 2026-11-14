package app.portolan

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Sizes every button and control shares, so the touch targets and the rows line up on every screen.
 * Text steps: 14 (notes), 16 (details), 18 (body and buttons), 20 (section heads), 24 (window titles), 28 (building names).
 * Corners: 12 buttons, 14 cards, 16 pop-up boxes, 20 windows.
 */
object UiSize {
    /** The least height of anything tapped. */
    val Touch = 48.dp
}

/** The one slider of the game: a round gold handle on a plain track (the stock handle is a thin bar and reads as clutter). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QtySlider(value: Float, onChange: (Float) -> Unit, range: ClosedFloatingPointRange<Float>, modifier: Modifier = Modifier) {
    val colors = SliderDefaults.colors(thumbColor = Gold, activeTrackColor = Gold, inactiveTrackColor = Color.White.copy(alpha = 0.2f),
        activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent)
    Slider(value = value, onValueChange = onChange, valueRange = range, colors = colors, modifier = modifier.height(UiSize.Touch),
        thumb = { Box(Modifier.size(28.dp).clip(CircleShape).background(Gold)) },
        track = { state -> SliderDefaults.Track(sliderState = state, colors = colors, modifier = Modifier.height(8.dp), thumbTrackGapSize = 0.dp,
            trackInsideCornerSize = 0.dp, drawStopIndicator = null) })
}

/** The one card of the game: a darker plate with an even gap between its lines. */
@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.clip(RoundedCornerShape(14.dp)).background(Navy.copy(alpha = 0.6f)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
}
